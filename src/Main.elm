port module Main exposing (..)

import Animation
import Animation.Messenger
import Browser
import Browser.Dom as Dom
import Dict exposing (Dict)
import Ease
import Habit exposing (Habit, HabitId)
import HabitStore exposing (..)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Json.Decode as JD
import Json.Encode as JE
import Parser
import Period exposing (Period(..), addToPosix, minusFromPosix)
import Random
import Random.Char
import Random.String
import Set exposing (..)
import Task
import Time exposing (Posix, posixToMillis)


type alias Anim =
    Animation.Messenger.State Msg


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
        -- TODO Show error when decoding fails
        storage =
            JD.decodeValue storageDecoder flags.model

        _ =
            case storage of
                Err err ->
                    Debug.log "Decode error " err |> (\_ -> "")

                _ ->
                    ""

        storage2 =
            Result.withDefault defaultStorageModel storage

        time =
            Time.millisToPosix flags.time
    in
    ( { time = time
      , habits = applyDeltas Dict.empty storage2.habits
      , options = storage2.options
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
    , habits : List HabitDelta
    , version : Int
    }


type alias Model =
    { time : Posix
    , habits : Dict HabitId Habit
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


type alias FormFields =
    Dict String String


type alias EditHabitScreen =
    { habitId : HabitId
    , fields : FormFields
    , deltas : List HabitStore.HabitFieldChange
    , parent : Screen
    }


type alias CreateHabitScreen =
    { fields : FormFields
    , deltas : List HabitStore.HabitFieldChange
    , parent : Screen
    }


type alias HabitForm a =
    { a
        | fields : FormFields
        , deltas : List HabitStore.HabitFieldChange
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
    -- TODO Subscribe to viewport change so we can redo this
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
    | DoCreateHabit (Maybe HabitId)
      -- Options
    | OpenEditOptions
    | DoSaveOptions
      -- Form Editing
    | ChangeFormField String String
    | BlurFormField String
    | Cancel
    | NewPageElement (Result Dom.Error Dom.Element)
    | ChangePage Int



{-
   So need to generate our random ID
   The best way is to probably :
       OnClick create we don't change pages yet
           We generate an id
           then we change pages and create
-}


habitToFields : Habit -> FormFields
habitToFields habit =
    let
        blocker =
            Habit.blockerId habit
                |> Maybe.map (\id -> ( "block", id ))
                |> Maybe.map List.singleton
                |> Maybe.withDefault []
    in
    Dict.fromList
        ([ ( "description", habit.description )
         , ( "tag", habit.tag )
         , ( "period", Period.toString habit.period )
         ]
            ++ blocker
        )


editHabitScreen : Model -> HabitId -> Maybe Screen
editHabitScreen model habitId =
    Dict.get habitId model.habits
        |> Maybe.map
            (\habit ->
                EditHabit
                    { habitId = habitId
                    , parent = model.screen
                    , deltas = []
                    , fields = habitToFields habit
                    }
            )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case ( model.screen, msg ) of
        ( _, NoOp ) ->
            ( model, Cmd.none )

        ( _, Tick time ) ->
            ( { model | time = time }
            , Cmd.none
            )

        ( _, AnimateScreen animMsg ) ->
            case model.screenTransition of
                Nothing ->
                    ( model, Cmd.none )

                Just (ScreenTransition transition) ->
                    let
                        ( style, cmd ) =
                            Animation.Messenger.update animMsg transition.style
                    in
                    ( { model | screenTransition = Just (ScreenTransition { transition | style = style }) }, cmd )

        ( _, Cancel ) ->
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
                , screenTransition = Just (flipOffRight model)
              }
            , Cmd.none
            )

        ( _, ClearTransition ) ->
            ( { model | screenTransition = Nothing }
            , Cmd.none
            )

        ( _, DoHabit habitId ) ->
            let
                newStore =
                    Dict.get habitId model.habits
                        |> Maybe.map (doHabitDeltas model.habits model.time)
                        |> Maybe.map (applyDeltas model.habits)
                        |> Maybe.withDefault model.habits
            in
            ( { model | habits = newStore }, Cmd.none ) |> storeModel

        ( _, OpenHabitEdit habitId ) ->
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

        ( _, OpenHabitSelect for habitId ) ->
            ( { model
                | screen =
                    SelectHabit
                        { page = 0
                        , selected = habitId
                        , forHabit = "\"" ++ for ++ "\""
                        , parent = model.screen
                        }
                , screenTransition = Just (flipOn model)
              }
            , Cmd.none
            )

        ( _, OpenHabitCreate ) ->
            ( { model
                | screen =
                    CreateHabit
                        { fields = habitToFields (HabitStore.emptyHabit "")
                        , deltas = []
                        , parent = model.screen
                        }
                , screenTransition =
                    Just (slideFromTopTransition model)
              }
            , Cmd.none
            )

        ( _, OpenEditOptions ) ->
            ( { model
                | screen =
                    EditOptions
                        { upcoming = Period.toString model.options.upcoming
                        , recent = Period.toString model.options.recent
                        , parent = model.screen
                        }
                , screenTransition = Just (slideFromTopTransition model)
              }
            , Cmd.none
            )

        ( _, NewPageElement (Ok el) ) ->
            ( { model | pageElement = Just el }, Cmd.none )

        ( _, NewPageElement _ ) ->
            ( { model | pageElement = Nothing }, Cmd.none )

        ( EditHabit screen, DoDeleteHabit ) ->
            let
                newStore =
                    deleteHabitDeltas model.habits model.time screen.habitId
                        |> applyDeltas model.habits
            in
            ( { model
                | habits = newStore
                , screen = screen.parent
                , screenTransition =
                    Just (slideOffbottom model)
              }
            , Cmd.none
            )
                |> storeModel

        ( EditHabit screen, DoEditHabit ) ->
            let
                newStore =
                    editHabitDeltas model.habits model.time screen.habitId screen.deltas
                        |> applyDeltas model.habits
            in
            ( { model
                | habits = newStore
                , screen = screen.parent
                , screenTransition =
                    Just (flipOffRight model)
              }
            , Cmd.none
            )
                |> storeModel

        ( SelectHabit { parent }, DoSelectHabit maybeHabitId ) ->
            let
                updateScreen screen =
                    case maybeHabitId of
                        Just habitId ->
                            { screen
                                | fields = Dict.insert "block" habitId screen.fields
                                , deltas =
                                    HabitStore.buildFieldChanges
                                        screen.deltas
                                        (HabitStore.BlockChange (Habit.Blocker habitId True))
                            }

                        Nothing ->
                            { screen
                                | fields = Dict.remove "block" screen.fields
                                , deltas =
                                    HabitStore.buildFieldChanges
                                        screen.deltas
                                        (HabitStore.BlockChange Habit.Unblocked)
                            }
            in
            ( { model
                | screen =
                    case parent of
                        EditHabit screen ->
                            EditHabit (updateScreen screen)

                        CreateHabit screen ->
                            CreateHabit (updateScreen screen)

                        _ ->
                            parent
                , screenTransition = Just (flipOffRight model)
              }
            , Cmd.none
            )

        ( CreateHabit screen, DoCreateHabit maybeId ) ->
            case maybeId of
                Nothing ->
                    let
                        idGenerator =
                            Random.map Just (Random.String.string 8 Random.Char.alchemicalSymbol)
                    in
                    ( model, Random.generate DoCreateHabit idGenerator )

                Just id ->
                    let
                        newStore =
                            addHabitDeltas model.habits model.time id screen.deltas
                                |> applyDeltas model.habits
                    in
                    ( { model
                        | habits = newStore
                        , screen = screen.parent
                        , screenTransition =
                            Just (flipOffRight model)
                      }
                    , Cmd.none
                    )
                        |> storeModel

        ( EditOptions screen, DoSaveOptions ) ->
            let
                options =
                    model.options

                updatedOptions =
                    { options
                        | recent = Period.parse screen.recent
                        , upcoming = Period.parse screen.upcoming
                    }
            in
            ( { model
                | options = updatedOptions
                , screen = screen.parent
                , screenTransition = Just (flipOffRight model)
              }
            , Cmd.none
            )
                |> storeModel

        ( EditHabit page, ChangeFormField field val ) ->
            ( { model | screen = EditHabit (updateHabitFormFields page field val) }
            , Cmd.none
            )

        ( CreateHabit page, ChangeFormField field val ) ->
            ( { model | screen = CreateHabit (updateHabitFormFields page field val) }
            , Cmd.none
            )

        ( EditOptions page, ChangeFormField field val ) ->
            case field of
                "recent" ->
                    ( { model | screen = EditOptions { page | recent = val } }
                    , Cmd.none
                    )

                "upcoming" ->
                    ( { model | screen = EditOptions { page | upcoming = val } }
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        ( HabitList screen, ChangePage page ) ->
            ( { model
                | screen = HabitList { screen | page = page }
                , screenTransition =
                    Just
                        (if page < screen.page then
                            flipOffRight model

                         else
                            flipOn model
                        )
              }
            , Cmd.none
            )

        ( SelectHabit screen, ChangePage page ) ->
            ( { model
                | screen = SelectHabit { screen | page = page }
                , screenTransition =
                    Just
                        (if page < screen.page then
                            flipOffRight model

                         else
                            flipOn model
                        )
              }
            , Cmd.none
            )

        ( _, _ ) ->
            ( model, Cmd.none )


updateHabitFormFields : HabitForm a -> String -> String -> HabitForm a
updateHabitFormFields page field val =
    case field of
        "description" ->
            { page
                | fields = Dict.insert "description" val page.fields
                , deltas =
                    HabitStore.buildFieldChanges
                        page.deltas
                        (HabitStore.DescriptionChange val)
            }

        "tag" ->
            { page
                | fields = Dict.insert "tag" val page.fields
                , deltas =
                    HabitStore.buildFieldChanges
                        page.deltas
                        (HabitStore.TagChange val)
            }

        "period" ->
            { page
                | fields = Dict.insert "period" val page.fields
                , deltas =
                    HabitStore.buildFieldChanges
                        page.deltas
                        (HabitStore.PeriodChange (Period.parse val))
            }

        _ ->
            page


habitOrderer : Model -> Habit -> Int
habitOrderer model habit =
    if shouldBeMarkedAsDone model habit then
        Maybe.withDefault model.time habit.lastDone
            |> Time.posixToMillis

    else
        -1 * (Time.posixToMillis habit.nextDue - Time.posixToMillis model.time)


visibleHabits : Model -> Dict HabitId Habit
visibleHabits model =
    Dict.filter (\k v -> viewHabitFilter model v) model.habits



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
            div
                [ class "static-page" ]
                [ viewScreen model model.screen ]

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
            , title = "today I will"
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
                |> Dict.values
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
            Dict.get "description" screen.fields
                |> Maybe.withDefault ""

        pageConfig =
            { showOptions = False
            , title = "edit \"" ++ title ++ "\""
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
    habitFieldsView screen.fields (Dict.values model.habits) (Just screen.habitId)



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
                    [ button [ onClick (DoCreateHabit Nothing) ] [ text "Create" ]
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
    habitFieldsView screen.fields (Dict.values model.habits) Nothing


getWithDefault : Dict String String -> String -> String -> String
getWithDefault dict default key =
    Dict.get key dict |> Maybe.withDefault default


habitFieldsView :
    Dict String String
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

        fieldGetter =
            getWithDefault fields ""

        -- TODO this should only change on blur of description field
        -- Should not be clickable if not filled out
        blockText =
            case Dict.get "block" fields of
                Nothing ->
                    "last time"

                Just hid ->
                    List.filter (\h -> h.id == hid) habits
                        |> List.head
                        |> Maybe.map .description
                        |> Maybe.withDefault "last time"
    in
    [ ( emptyDiv, label [] [ text "I want to" ] )
    , ( emptyDiv
      , input
            [ placeholder "Do Something", value (fieldGetter "description"), onInput (ChangeFormField "description") ]
            []
      )
    , ( emptyDiv, label [] [ text "every" ] )
    , ( periodOptionsView (fieldGetter "period") "period-list"
      , input
            -- TODO Select entire description when clicked
            [ placeholder "Day", value (fieldGetter "period"), list "period-list", onInput (ChangeFormField "period") ]
            []
      )
    , ( emptyDiv, label [] [ text "after" ] )
    , ( emptyDiv
      , button
            [ class "habit-button-select", onClick (OpenHabitSelect (fieldGetter "description") (Dict.get "block" fields)) ]
            [ text blockText ]
      )
    , ( emptyDiv, label [] [ text "category" ] )
    , ( datalist
            [ id "tag-list" ]
            tagOptions
      , input
            [ placeholder "Todo", value (fieldGetter "tag"), list "tag-list", onInput (ChangeFormField "tag") ]
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
                    [ value screen.upcoming, list "upcoming-list", onInput (ChangeFormField "upcoming") ]
                    []
              )
            , ( emptyDiv, label [] [ text "Show recently done" ] )
            , ( periodOptionsView screen.recent "recent-list"
              , input
                    [ value screen.recent, list "recent-list", onInput (ChangeFormField "recent") ]
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
            Dict.values model.habits
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
    StorageModel defaultOptions [] 0


storageDecoder : JD.Decoder StorageModel
storageDecoder =
    JD.map3 StorageModel
        (JD.field "options" optionsDecoder)
        (JD.field "habits" (JD.list HabitStore.decoder))
        (JD.succeed 0)


storageEncoder : Model -> JE.Value
storageEncoder model =
    JE.object
        [ ( "options", optionsEncoder model.options )
        , ( "habits", JE.list HabitStore.encode (HabitStore.deltasFromDict model.time model.habits) )
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


emptyDiv : Html Msg
emptyDiv =
    div [] []


pageLines : Int
pageLines =
    18


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
    TODO
    - fix overflow for bottom/right transitions
    - Make them faster

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
-}


slideFromTopTransition : Model -> ScreenTransition
slideFromTopTransition { screen, pageElement } =
    let
        top =
            case pageElement of
                Nothing ->
                    0

                Just el ->
                    -1 * (el.element.y + el.element.height)
    in
    ScreenTransition
        { previous = screen
        , direction = TransitionIn
        , style =
            Animation.interrupt
                [ Animation.to [ Animation.top (Animation.px 0) ]
                , Animation.Messenger.send ClearTransition
                ]
                (Animation.style
                    [ Animation.top (Animation.px top)
                    ]
                )
        }


slideOffbottom : Model -> ScreenTransition
slideOffbottom { screen, pageElement } =
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


slideEase =
    Animation.easing
        { duration = 400
        , ease = Ease.inOutCubic
        }


flipOffRight : Model -> ScreenTransition
flipOffRight { screen, pageElement } =
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
                [ Animation.toWith
                    slideEase
                    [ Animation.left (Animation.px left) ]
                , Animation.set [ Animation.exactly "z-index" "1" ]
                , Animation.toWith
                    slideEase
                    [ Animation.left (Animation.px 0) ]
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
                [ Animation.toWith slideEase [ Animation.right (Animation.px right) ]
                , Animation.set [ Animation.exactly "z-index" "1" ]
                , Animation.toWith slideEase [ Animation.right (Animation.px 0) ]
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
                [ Animation.toWith slideEase [ Animation.right (Animation.px right) ]
                , Animation.set [ Animation.exactly "z-index" "2" ]
                , Animation.toWith slideEase [ Animation.right (Animation.px 0) ]
                , Animation.Messenger.send ClearTransition
                ]
                (Animation.style
                    [ Animation.top (Animation.px 0)
                    , Animation.right (Animation.px 0)
                    , Animation.exactly "z-index" "1"
                    ]
                )
        }
