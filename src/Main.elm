port module Main exposing (..)

import Animation
import Animation.Messenger
import Browser
import Browser.Dom as Dom
import Dict exposing (Dict)
import Ease
import Habit exposing (Habit, HabitId)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Json.Decode as JD
import Json.Encode as JE
import Parser
import Period exposing (Period(..), addToPosix, minusFromPosix)
import Set exposing (..)
import Store exposing (Store)
import Task
import Time exposing (Posix, posixToMillis)


type alias Anim =
    Animation.Messenger.State Msg


pageLines : Int
pageLines =
    18


main : Program Flags Model Msg
main =
    Browser.document
        { init = init
        , view = \model -> { title = "Habits", body = [ view model ] }
        , update = update
        , subscriptions = subscriptions
        }


init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        -- TODO should show error instead of with default
        storage =
            JD.decodeValue storageDecoder flags.model
                |> Result.withDefault defaultStorageModel

        time =
            Time.millisToPosix flags.time
    in
    ( { time = time
      , habits = storage.habits
      , options = storage.options
      , screen = HabitList { page = 0 }
      , screenTransition = Nothing
      , pageElement = Nothing
      }
    , getPageElement
    )



-- MODEL


type alias Flags =
    { time : Int, model : JD.Value }


type alias StorageModel =
    { options : Options
    , habits : Store Habit
    , version : Int
    }


type alias Model =
    { time : Posix
    , habits : Store Habit
    , options : Options
    , screen : Screen
    , screenTransition : Maybe ScreenTransition
    , pageElement : Maybe Dom.Element
    }


type alias Options =
    { recent : Period
    , upcoming : Period
    }


defaultOptions =
    { recent = Hours 12
    , upcoming = Hours 12
    }


type Screen
    = HabitList HabitListScreen
    | EditHabit EditHabitScreen
    | CreateHabit CreateHabitScreen
    | SelectHabit SelectHabitScreen
    | EditOptions EditOptionsScreen


type alias HabitListScreen =
    { page : Int }


type alias EditHabitScreen =
    { habitId : HabitId
    , description : String
    , tag : String
    , period : String
    , block : Maybe String
    , parent : Screen
    }


type alias CreateHabitScreen =
    { description : String
    , tag : String
    , period : String
    , block : Maybe String
    , parent : Screen
    }


type alias SelectHabitScreen =
    { page : Int
    , selected : Maybe HabitId
    , forHabit : String
    , parent : Screen
    }


type alias EditOptionsScreen =
    { upcoming : String
    , recent : String
    , parent : Screen
    }


type TransitionDirection
    = TransitionIn
    | TransitionOut


type ScreenTransition
    = ScreenTransition
        { previous : Screen
        , style : Anim
        , direction : TransitionDirection
        }


type alias HabitFields a =
    { a
        | description : String
        , tag : String
        , period : String
        , block : Maybe String
    }



-- SUBSCRIPTIONS


animationSubscription : Model -> Sub Msg
animationSubscription model =
    case model.screenTransition of
        Nothing ->
            Sub.none

        Just (ScreenTransition { style }) ->
            Animation.subscription
                AnimateScreen
                [ style ]


timeSubscription : Model -> Sub Msg
timeSubscription model =
    Time.every 1000 Tick


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch [ timeSubscription model, animationSubscription model ]


getPageElement : Cmd Msg
getPageElement =
    -- TODO need to handle viewport resize.
    Task.attempt NewPageElement (Dom.getElement "habits-view")



-- PORTS


port store : JE.Value -> Cmd msg


storeModel : ( Model, Cmd msg ) -> ( Model, Cmd msg )
storeModel ( model, cmd ) =
    ( model, Cmd.batch [ cmd, store (storageEncoder model) ] )



-- UPDATE


type Msg
    = NoOp
    | NoOps String
    | Tick Time.Posix
      -- Screen Transition
    | AnimateScreen Animation.Msg
    | ClearTransition
      -- From list screen
    | DoHabit HabitId
      -- Habit Edit
    | OpenHabitEdit HabitId
    | DoDeleteHabit
    | DoEditHabit
      -- Habit Selection
    | OpenHabitSelect String (Maybe HabitId)
    | DoSelectHabit (Maybe HabitId)
      -- Habit Creation
    | OpenHabitCreate
    | DoCreateHabit
      -- Options
    | OpenEditOptions
    | DoSaveOptions
      -- Form Editing
    | ChangeFormField FormChangeMsg
    | Cancel
    | NewPageElement (Result Dom.Error Dom.Element)
    | ChangePage Int


type FormChangeMsg
    = ChangeDescription String
    | ChangeTag String
    | ChangePeriod String
    | ToggleBlocked
    | ChangeBlocked String
    | ChangeOptionsRecent String
    | ChangeOptionsUpcoming String


editHabitScreen : Model -> HabitId -> Maybe Screen
editHabitScreen model habitId =
    Store.get habitId model.habits
        |> Maybe.map
            (\habit ->
                EditHabit { habitId = habitId, parent = model.screen, description = habit.description, tag = habit.tag, period = Period.toString habit.period, block = Habit.getBlocker habit }
            )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NoOp ->
            ( model, Cmd.none )

        NoOps s ->
            ( model, Cmd.none )

        Tick time ->
            ( { model | time = time }
            , Cmd.none
            )

        AnimateScreen animMsg ->
            case model.screenTransition of
                Nothing ->
                    ( model, Cmd.none )

                Just (ScreenTransition transition) ->
                    let
                        ( style, cmd ) =
                            Animation.Messenger.update animMsg transition.style
                    in
                    ( { model | screenTransition = Just (ScreenTransition { transition | style = style }) }, cmd )

        ClearTransition ->
            ( { model | screenTransition = Nothing }
            , Cmd.none
            )

        DoHabit habitId ->
            let
                updatedHabit =
                    Store.filterIds ((==) habitId) model.habits
                        |> Store.mapValues (Habit.doHabit model.time)
                        |> Store.union model.habits

                updatedBlocked =
                    Store.filterValues (Habit.isBlocker habitId) updatedHabit
                        |> Store.mapValues (Habit.unblock model.time)
                        |> Store.union updatedHabit
            in
            ( { model
                | habits =
                    Store.filterIds ((==) habitId) model.habits
                        |> Store.mapValues (Habit.doHabit model.time)
                        |> Store.union model.habits
              }
            , Cmd.none
            )
                |> storeModel

        OpenHabitEdit habitId ->
            let
                maybeScreen =
                    editHabitScreen model habitId
            in
            case maybeScreen of
                Nothing ->
                    ( model, Cmd.none )

                Just newScreen ->
                    ( { model
                        | screen = newScreen
                        , screenTransition = Just (flipOn model)
                      }
                    , Cmd.none
                    )

        DoDeleteHabit ->
            case model.screen of
                EditHabit { habitId, parent } ->
                    ( { model
                        | habits =
                            Store.delete habitId model.habits
                                |> Store.mapValues
                                    (\habit ->
                                        if Habit.isBlocker habitId habit then
                                            { habit | block = Habit.Unblocked }

                                        else
                                            habit
                                    )
                        , screen = parent
                        , screenTransition =
                            Just (slideOffbottom model)
                      }
                    , Cmd.none
                    )
                        |> storeModel

                _ ->
                    ( model, Cmd.none )

        DoEditHabit ->
            case model.screen of
                EditHabit fields ->
                    ( { model
                        | habits =
                            Store.filterIds ((==) fields.habitId) model.habits
                                |> Store.mapValues
                                    (\habit ->
                                        { habit
                                            | description = fields.description
                                            , tag = fields.tag
                                            , period = Period.parse fields.period
                                            , block =
                                                case ( fields.block, habit.block ) of
                                                    ( Nothing, _ ) ->
                                                        Habit.Unblocked

                                                    ( Just hid, Habit.Blocker _ True ) ->
                                                        Habit.Blocker hid True

                                                    ( Just hid, Habit.Blocker _ False ) ->
                                                        Habit.Blocker hid False

                                                    ( Just hid, Habit.Unblocked ) ->
                                                        Habit.Blocker hid False
                                        }
                                    )
                                |> Store.union model.habits
                        , screen = fields.parent
                        , screenTransition = Just (flipOffRight model)
                      }
                    , Cmd.none
                    )
                        |> storeModel

                _ ->
                    ( model, Cmd.none )

        OpenHabitSelect for habitId ->
            ( { model
                | screen = SelectHabit { page = 0, selected = habitId, forHabit = "last " ++ for, parent = model.screen }
                , screenTransition = Just (flipOn model)
              }
            , Cmd.none
            )

        DoSelectHabit habitId ->
            case model.screen of
                SelectHabit { parent } ->
                    ( { model
                        | screen =
                            case parent of
                                EditHabit screen ->
                                    EditHabit { screen | block = habitId }

                                CreateHabit screen ->
                                    CreateHabit { screen | block = habitId }

                                _ ->
                                    parent
                        , screenTransition = Just (flipOffRight model)
                      }
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        OpenHabitCreate ->
            ( { model
                | screen =
                    CreateHabit
                        { description = ""
                        , tag = ""
                        , period = ""
                        , block = Nothing
                        , parent = model.screen
                        }
                , screenTransition =
                    Just (slideFromTopTransition model)
              }
            , Cmd.none
            )

        DoCreateHabit ->
            -- TODO THIS SHOULD MAKE SURE DESCRIPTION IS FILLED
            case model.screen of
                CreateHabit fields ->
                    let
                        newHabit =
                            Habit.newHabit
                                model.time
                                fields.description
                                fields.tag
                                (Store.getNextId model.habits)
                                (Period.parse fields.period)
                                fields.block
                    in
                    ( { model
                        | habits = Store.insert newHabit model.habits
                        , screen = fields.parent
                        , screenTransition = Just (flipOffRight model)
                      }
                    , Cmd.none
                    )
                        |> storeModel

                _ ->
                    ( model, Cmd.none )

        OpenEditOptions ->
            ( { model
                | screen =
                    EditOptions
                        { upcoming = Period.toString model.options.upcoming
                        , recent = Period.toString model.options.recent
                        , parent = model.screen
                        }
                , screenTransition = Just (flipOn model)
              }
            , Cmd.none
            )

        DoSaveOptions ->
            case model.screen of
                EditOptions fields ->
                    let
                        options =
                            model.options

                        updatedOptions =
                            { options
                                | recent = Period.parse fields.recent
                                , upcoming = Period.parse fields.upcoming
                            }
                    in
                    ( { model | options = updatedOptions, screen = fields.parent, screenTransition = Just (flipOffRight model) }
                    , Cmd.none
                    )
                        |> storeModel

                _ ->
                    ( model, Cmd.none )

        ChangeFormField formChangeMsg ->
            case ( formChangeMsg, model.screen ) of
                ( ChangeDescription str, EditHabit page ) ->
                    ( { model | screen = EditHabit { page | description = str } }
                    , Cmd.none
                    )

                ( ChangeDescription str, CreateHabit page ) ->
                    ( { model | screen = CreateHabit { page | description = str } }
                    , Cmd.none
                    )

                ( ChangeTag str, EditHabit page ) ->
                    ( { model | screen = EditHabit { page | tag = str } }
                    , Cmd.none
                    )

                ( ChangeTag str, CreateHabit page ) ->
                    ( { model | screen = CreateHabit { page | tag = str } }
                    , Cmd.none
                    )

                ( ChangePeriod str, EditHabit page ) ->
                    ( { model | screen = EditHabit { page | period = str } }
                    , Cmd.none
                    )

                ( ChangePeriod str, CreateHabit page ) ->
                    ( { model | screen = CreateHabit { page | period = str } }
                    , Cmd.none
                    )

                ( ChangeOptionsRecent str, EditOptions page ) ->
                    ( { model | screen = EditOptions { page | recent = str } }
                    , Cmd.none
                    )

                ( ChangeOptionsUpcoming str, EditOptions page ) ->
                    ( { model | screen = EditOptions { page | upcoming = str } }
                    , Cmd.none
                    )

                ( _, _ ) ->
                    ( model, Cmd.none )

        Cancel ->
            let
                prev =
                    case model.screen of
                        HabitList _ ->
                            model.screen

                        EditHabit { parent } ->
                            parent

                        CreateHabit { parent } ->
                            parent

                        EditOptions { parent } ->
                            parent

                        SelectHabit { parent } ->
                            parent
            in
            ( { model
                | screen = prev
                , screenTransition = Just (flipOffLeft model)
              }
            , Cmd.none
            )

        NewPageElement (Ok el) ->
            ( { model | pageElement = Just el }, Cmd.none )

        NewPageElement _ ->
            ( { model | pageElement = Nothing }, Cmd.none )

        ChangePage page ->
            case model.screen of
                HabitList screen ->
                    ( { model
                        | screen = HabitList { screen | page = page }
                        , screenTransition =
                            Just
                                (if page < screen.page then
                                    flipOffLeft model

                                 else
                                    flipOn model
                                )
                      }
                    , Cmd.none
                    )

                SelectHabit screen ->
                    ( { model
                        | screen = SelectHabit { screen | page = page }
                        , screenTransition =
                            Just
                                (if page < screen.page then
                                    flipOffLeft model

                                 else
                                    flipOn model
                                )
                      }
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )


habitOrderer : Model -> Habit -> Int
habitOrderer model habit =
    if shouldBeMarkedAsDone model habit then
        Maybe.withDefault model.time habit.lastDone
            |> Time.posixToMillis

    else
        -1 * (Time.posixToMillis habit.nextDue - Time.posixToMillis model.time)


visibleHabits : Model -> Store Habit
visibleHabits model =
    Store.filterValues (viewHabitFilter model) model.habits



-- VIEW


view : Model -> Html Msg
view model =
    div
        [ class "page-container", id "habits-view" ]
        [ div
            []
            [ maybeViewTransition model ]
        ]


maybeViewTransition : Model -> Html Msg
maybeViewTransition model =
    case model.screenTransition of
        Nothing ->
            viewScreen model model.screen

        Just transition ->
            viewScreenTransition model transition


viewScreenTransition : Model -> ScreenTransition -> Html Msg
viewScreenTransition model (ScreenTransition transition) =
    let
        ( top, bottom ) =
            case transition.direction of
                TransitionIn ->
                    ( model.screen, transition.previous )

                TransitionOut ->
                    ( transition.previous, model.screen )
    in
    div
        []
        [ div
            [ class "static-page" ]
            [ viewScreen model bottom ]
        , div
            (class "transition-page"
                :: Animation.render transition.style
            )
            [ viewScreen model top ]
        ]


viewScreen : Model -> Screen -> Html Msg
viewScreen model page =
    case page of
        HabitList habitList ->
            viewHabitsListPage model habitList

        EditHabit editPage ->
            viewEditingPage model editPage

        CreateHabit newPage ->
            viewNewPage model newPage

        EditOptions optionsPage ->
            viewOptionsPage model optionsPage

        SelectHabit habitSelect ->
            viewHabitSelectPage model habitSelect



-- HABITS VIEW


viewHabitsListPage : Model -> HabitListScreen -> Html Msg
viewHabitsListPage model habitListScreen =
    let
        pageConfig =
            { showOptions = True
            , title = "Today I will"
            , footer =
                ( button
                    [ class "add-habit", onClick OpenHabitCreate ]
                    [ text "+" ]
                , emptyDiv
                )
            , nLines = pageLines
            }

        pageState =
            { pageNumber = habitListScreen.page }

        { time, options, habits } =
            model

        lines =
            visibleHabits model
                |> Store.values
                |> List.sortBy (habitOrderer model)
                |> List.map (habitViewLine model)
    in
    viewPage pageConfig pageState lines


habitViewLine : Model -> Habit -> PageLine
habitViewLine model habit =
    ( button
        [ class "habit-edit"
        , onClick (OpenHabitEdit habit.id)
        ]
        [ text "..." ]
    , button
        [ class "habit-button"
        , class
            (if shouldBeMarkedAsDone model habit then
                "habit-done"

             else
                "habit-todo"
            )
        , onClick (DoHabit habit.id)
        ]
        [ span
            [ class "habit-description" ]
            [ text habit.description ]
        , span
            [ class "habit-tag" ]
            [ text habit.tag ]
        ]
    )



-- EDIT VIEW


viewEditingPage : Model -> EditHabitScreen -> Html Msg
viewEditingPage model screen =
    let
        title =
            screen.description

        pageConfig =
            { showOptions = False
            , title = "Edit " ++ title
            , footer =
                ( emptyDiv
                , div
                    [ class "button-line" ]
                    [ button [ onClick DoEditHabit ] [ text "Save" ]
                    , button [ onClick DoDeleteHabit ] [ text "Delete" ]
                    , button [ onClick Cancel ] [ text "Cancel" ]
                    ]
                )
            , nLines = pageLines
            }

        pageState =
            { pageNumber = 0 }

        lines =
            editPagelines model screen
    in
    viewPage pageConfig pageState lines


editPagelines : Model -> EditHabitScreen -> PageLines
editPagelines model screen =
    habitFieldsView screen (Store.values model.habits) (Just screen.habitId)



-- NEW VIEW


viewNewPage : Model -> CreateHabitScreen -> Html Msg
viewNewPage model screen =
    let
        pageConfig =
            { showOptions = False
            , title = "new habit"
            , footer =
                ( emptyDiv
                , div
                    [ class "button-line" ]
                    [ button [ onClick DoCreateHabit ] [ text "Create" ]
                    , button [ onClick Cancel ] [ text "Cancel" ]
                    ]
                )
            , nLines = pageLines
            }

        pageState =
            { pageNumber = 0 }

        lines =
            createPagelines model screen
    in
    viewPage pageConfig pageState lines


createPagelines : Model -> CreateHabitScreen -> PageLines
createPagelines model screen =
    habitFieldsView screen (Store.values model.habits) Nothing


habitFieldsView :
    HabitFields a
    -> List Habit
    -> Maybe HabitId
    -> PageLines
habitFieldsView fields habits maybeHabit =
    let
        tagOption tag =
            option [ value tag ] [ text tag ]

        tagOptions =
            List.map .tag habits
                |> Set.fromList
                |> Set.toList
                |> List.map tagOption

        -- TODO this should only change on blur of description field
        -- Should not be clickable if not filled out
        blockText =
            case fields.block of
                Nothing ->
                    "last did"

                Just hid ->
                    List.filter (\h -> h.id == hid) habits
                        |> List.head
                        |> Maybe.map .description
                        |> Maybe.withDefault "last did"
    in
    [ ( emptyDiv, label [] [ text "I want to" ] )
    , ( emptyDiv
      , input
            [ placeholder "Do Something", value fields.description, onInput (\s -> ChangeFormField (ChangeDescription s)) ]
            []
      )
    , ( emptyDiv, label [] [ text "every" ] )
    , ( periodOptionsView fields.period "period-list"
      , input
            -- TODO THIS SHOULD select entire thing when clicked.
            [ placeholder "Day", value fields.period, list "period-list", onInput (\s -> ChangeFormField (ChangePeriod s)) ]
            []
      )
    , ( emptyDiv, label [] [ text "after I" ] )
    , ( emptyDiv
      , button
            [ class "habit-button-select", onClick (OpenHabitSelect fields.description fields.block) ]
            [ text blockText ]
      )
    , ( emptyDiv, label [] [ text "category" ] )
    , ( datalist
            [ id "tag-list" ]
            tagOptions
      , input
            [ placeholder "Todo", value fields.tag, list "tag-list", onInput (\s -> ChangeFormField (ChangeTag s)) ]
            []
      )
    ]



-- OPTIONS VIEW


viewOptionsPage : Model -> EditOptionsScreen -> Html Msg
viewOptionsPage model screen =
    let
        pageConfig =
            { showOptions = False
            , title = "View Options"
            , footer =
                ( emptyDiv
                , div
                    [ class "button-line" ]
                    [ button [ onClick DoSaveOptions ] [ text "Save" ]
                    , button [ onClick Cancel ] [ text "Cancel" ]
                    ]
                )
            , nLines = pageLines
            }

        pageState =
            { pageNumber = 0 }

        lines =
            [ ( emptyDiv, label [] [ text "Show upcoming" ] )
            , ( periodOptionsView screen.upcoming "upcoming-list"
              , input
                    [ value screen.upcoming, list "upcoming-list", onInput (\s -> ChangeFormField (ChangeOptionsUpcoming s)) ]
                    []
              )
            , ( emptyDiv, label [] [ text "Show recently done" ] )
            , ( periodOptionsView screen.recent "recent-list"
              , input
                    [ value screen.recent, list "recent-list", onInput (\s -> ChangeFormField (ChangeOptionsRecent s)) ]
                    []
              )
            ]
    in
    viewPage pageConfig pageState lines



-- Other helpers


periodOptionsView : String -> String -> Html Msg
periodOptionsView input for =
    let
        periodUnit =
            Result.withDefault
                1
                (Parser.run Parser.int input)

        periodOption period =
            option
                [ value (Period.toString period) ]
                [ text (Period.toString period) ]

        periodOptions unit =
            [ periodOption (Minutes unit)
            , periodOption (Hours unit)
            , periodOption (Days unit)
            , periodOption (Weeks unit)
            , periodOption (Months unit)
            ]
    in
    datalist
        [ id for ]
        (periodOptions periodUnit ++ periodOptions (periodUnit + 1))


viewHabitSelectPage : Model -> SelectHabitScreen -> Html Msg
viewHabitSelectPage model screen =
    let
        pageConfig =
            { showOptions = False
            , title = screen.forHabit ++ " after"
            , footer =
                ( emptyDiv
                , div
                    [ class "button-line" ]
                    [ button [ onClick Cancel ] [ text "Cancel" ]
                    ]
                )
            , nLines = pageLines
            }

        pageState =
            { pageNumber = screen.page }

        { time, options, habits } =
            model

        lines =
            Store.values model.habits
                |> List.sortBy .description
                |> List.map (habitSelectLine model)
    in
    viewPage pageConfig pageState lines


habitSelectLine : Model -> Habit -> PageLine
habitSelectLine model habit =
    ( emptyDiv
    , button
        [ class "habit-button"
        , onClick (DoSelectHabit (Just habit.id))
        ]
        [ span
            [ class "habit-description" ]
            [ text habit.description ]
        , span
            [ class "habit-tag" ]
            [ text habit.tag ]
        ]
    )



-- Line helpers


emptyDiv =
    div [] []



-- Due Helpers
-- TODO move some of these into habit


isDueSoon : Model -> Habit -> Bool
isDueSoon { time, options } habit =
    posixToMillis habit.nextDue
        < posixToMillis (addToPosix options.upcoming time)


isRecentlyDone : Model -> Habit -> Bool
isRecentlyDone { time, options } habit =
    habit.lastDone
        |> Maybe.map (\l -> posixToMillis l > posixToMillis (minusFromPosix options.recent time))
        |> Maybe.withDefault False


shouldBeMarkedAsDone : Model -> Habit -> Bool
shouldBeMarkedAsDone model habit =
    if Habit.isBlocked habit then
        True

    else
        not (isDueSoon model habit)


viewHabitFilter : Model -> Habit -> Bool
viewHabitFilter model habit =
    let
        due =
            isDueSoon model habit

        recent =
            isRecentlyDone model habit
    in
    if Habit.isBlocked habit then
        recent

    else
        due || recent



-- Encode/Decode


defaultStorageModel : StorageModel
defaultStorageModel =
    StorageModel defaultOptions (Store.empty Store.RandomId) 0


storageDecoder : JD.Decoder StorageModel
storageDecoder =
    JD.map3 StorageModel
        (JD.field "options" optionsDecoder)
        (JD.field "habits" (Store.decode Habit.decoder))
        (JD.succeed 0)


storageEncoder : Model -> JE.Value
storageEncoder model =
    JE.object
        [ ( "options", optionsEncoder model.options )
        , ( "habits", Store.encode Habit.encode model.habits )
        , ( "version", JE.int 0 )
        ]


optionsDecoder : JD.Decoder Options
optionsDecoder =
    JD.map2 Options
        (JD.field "recent" Period.decoder)
        (JD.field "upcoming" Period.decoder)


optionsEncoder : Options -> JE.Value
optionsEncoder options =
    JE.object
        [ ( "recent", Period.encode options.recent )
        , ( "upcoming", Period.encode options.upcoming )
        ]



-- Page view helpers


type alias PageConfig =
    { showOptions : Bool
    , title : String
    , footer : PageLine
    , nLines : Int
    }


type alias PageState =
    { pageNumber : Int
    }


type alias PageLine =
    ( Html Msg, Html Msg )


type alias PageLines =
    List PageLine


cullPageLines : PageConfig -> PageState -> PageLines -> PageLines
cullPageLines { nLines } { pageNumber } lines =
    lines
        |> List.drop (pageNumber * nLines)
        |> List.take nLines


viewPageLine : PageLine -> Html Msg
viewPageLine ( margin, content ) =
    div
        [ class "page-line" ]
        [ div
            [ class "margin" ]
            [ margin ]
        , div
            [ class "line-content" ]
            [ content ]
        ]


viewEmptyLine : Html Msg
viewEmptyLine =
    div
        [ class "page-line" ]
        [ div
            [ class "margin" ]
            [ emptyDiv ]
        , div
            [ class "line-content" ]
            [ emptyDiv ]
        ]


viewPageLines : PageLines -> PageLine -> Html Msg
viewPageLines lines footer =
    div
        [ class "page-lines" ]
        (List.map viewPageLine
            (lines
                ++ [ footer ]
            )
        )


viewPageFooter : PageConfig -> PageState -> PageLines -> Html Msg
viewPageFooter { nLines } { pageNumber } lines =
    -- TODO hook these up to next/prev pages
    div
        [ class "page-foot" ]
        [ div
            [ class "margin" ]
            (if pageNumber > 0 then
                [ button
                    [ class "add-habit", onClick (ChangePage (pageNumber - 1)) ]
                    [ text "<" ]
                ]

             else
                []
            )
        , div
            [ class "line-content" ]
            (if List.length lines > nLines then
                [ button
                    [ class "add-habit", onClick (ChangePage (pageNumber + 1)) ]
                    [ text ">" ]
                ]

             else
                []
            )
        ]


viewPage : PageConfig -> PageState -> PageLines -> Html Msg
viewPage config state lines =
    let
        culledLines =
            cullPageLines config state lines

        nEmptyLines =
            config.nLines - List.length culledLines
    in
    div
        [ class "page" ]
        [ div
            [ class "page-head" ]
            [ div
                [ class "margin" ]
                (if config.showOptions then
                    [ button
                        [ class "add-habit", onClick OpenEditOptions ]
                        [ text "-" ]
                    ]

                 else
                    []
                )
            , div
                [ class "line-content" ]
                [ text config.title ]
            ]
        , viewPageLines (cullPageLines config state lines) config.footer
        , div
            []
            (List.range 1 nEmptyLines |> List.map (\i -> viewEmptyLine))
        , viewPageFooter config state lines
        ]



-- Transition helpers
{-
   For accuracy store viewport dimensions (need to sub to task)
   Also find page container dimensions for the flip through
   can use animation.set for zindex.
-}


slideFromTopTransition : Model -> ScreenTransition
slideFromTopTransition { screen, pageElement } =
    let
        bottom =
            case pageElement of
                Nothing ->
                    0

                Just el ->
                    el.element.y + el.element.height
    in
    ScreenTransition
        { previous = screen
        , direction = TransitionIn
        , style =
            Animation.interrupt
                [ Animation.to [ Animation.bottom (Animation.px 0) ]
                , Animation.Messenger.send ClearTransition
                ]
                (Animation.style
                    [ Animation.bottom (Animation.px bottom)
                    ]
                )
        }


slideOffbottom : Model -> ScreenTransition
slideOffbottom { screen, pageElement } =
    -- TODO need to fix overflow
    -- Our visible area should be (100 vw) * page height + margins.
    let
        top =
            case pageElement of
                Nothing ->
                    0

                Just el ->
                    el.viewport.height + (el.element.y * 2)
    in
    ScreenTransition
        { previous = screen
        , direction = TransitionOut
        , style =
            Animation.interrupt
                [ Animation.to [ Animation.top (Animation.px top) ]
                , Animation.Messenger.send ClearTransition
                ]
                (Animation.style
                    [ Animation.top (Animation.px 0)
                    ]
                )
        }


flipOffRight : Model -> ScreenTransition
flipOffRight { screen, pageElement } =
    -- TODO need to fix overflow
    -- Our visible area should be (100 vw) * page height + margins.
    let
        left =
            case pageElement of
                Nothing ->
                    0

                Just el ->
                    el.element.width
    in
    ScreenTransition
        { previous = screen
        , direction = TransitionOut
        , style =
            Animation.interrupt
                [ Animation.to [ Animation.left (Animation.px left) ]
                , Animation.set [ Animation.exactly "z-index" "1" ]
                , Animation.to [ Animation.left (Animation.px 0) ]
                , Animation.Messenger.send ClearTransition
                ]
                (Animation.style
                    [ Animation.top (Animation.px 0)
                    , Animation.left (Animation.px 0)
                    , Animation.exactly "z-index" "2"
                    ]
                )
        }


flipOffLeft : Model -> ScreenTransition
flipOffLeft { screen, pageElement } =
    -- TODO need to fix overflow
    -- Our visible area should be (100 vw) * page height + margins.
    let
        right =
            case pageElement of
                Nothing ->
                    0

                Just el ->
                    el.element.width
    in
    ScreenTransition
        { previous = screen
        , direction = TransitionOut
        , style =
            Animation.interrupt
                [ Animation.to [ Animation.right (Animation.px right) ]
                , Animation.set [ Animation.exactly "z-index" "1" ]
                , Animation.to [ Animation.right (Animation.px 0) ]
                , Animation.Messenger.send ClearTransition
                ]
                (Animation.style
                    [ Animation.top (Animation.px 0)
                    , Animation.right (Animation.px 0)
                    , Animation.exactly "z-index" "2"
                    ]
                )
        }


flipOn : Model -> ScreenTransition
flipOn { screen, pageElement } =
    let
        right =
            case pageElement of
                Nothing ->
                    0

                Just el ->
                    el.element.width
    in
    ScreenTransition
        { previous = screen
        , direction = TransitionIn
        , style =
            Animation.interrupt
                [ Animation.to [ Animation.right (Animation.px right) ]
                , Animation.set [ Animation.exactly "z-index" "2" ]
                , Animation.to [ Animation.right (Animation.px 0) ]
                , Animation.Messenger.send ClearTransition
                ]
                (Animation.style
                    [ Animation.top (Animation.px 0)
                    , Animation.right (Animation.px 0)
                    , Animation.exactly "z-index" "1"
                    ]
                )
        }



{-
         Type of transitions

      slideFromTop (old one static, new one slide in)
           New Habit
      slideOffbottom (old one slide out, new one static)
           Delete habit
      flipOffRight (old one slide off - need z index, new one static)
           Prev Page Page, save (all of them), Select habit
      flipOffLeft (old one slide off - need z index, new one static)
           Cancel (all of them)
      flipOn (old one static, new one slide in - need z index)
           Next Page

   -- Transitions
      initalPageTransitionStyle =
          Animation.styleWith
              (Animation.easing
                  { duration = 750
                  , ease = Ease.inOutQuart
                  }
              )
              [ Animation.right (Animation.px 0) ]


      pageTransitionStyle model =
          Animation.interrupt
              [ Animation.to [ Animation.right (Animation.px -510) ]
              , Animation.Messenger.send (SwapPages (Store.getNextId model.pageTransitions))
              , Animation.to [ Animation.right (Animation.px 0) ]
              , Animation.Messenger.send (ClearTransition (Store.getNextId model.pageTransitions))
              ]


      openPageTransition : Model -> PageTransition
      openPageTransition model =
          Transition
              { previous = { model | pageTransitions = Store.empty Store.IncrementalId }
              , style = pageTransitionStyle model initalPageTransitionStyle
              , above = True
              }

-}
