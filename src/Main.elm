port module Main exposing (..)

import Animation
import Animation.Messenger
import Browser
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
      , page = HabitList { pageNumber = 0 }
      , pageTransitions = Store.empty Store.IncrementalId
      , pageLines = 20
      }
    , Cmd.none
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
    , page : Page
    , pageTransitions : Store PageTransition
    , pageLines : Int
    }


type Page
    = HabitList HabitListPage
    | EditHabit EditPage
    | NewHabit NewPage
    | ChangeOptions OptionsPage


type PageTransition
    = Transition
        { previous : Model
        , style : Anim
        , above : Bool
        }


type alias HabitListPage =
    { pageNumber : Int
    }


type alias EditPage =
    { id : HabitId
    , description : String
    , tag : String
    , period : String
    , block : Maybe HabitId
    }


type alias HabitFields a =
    { a
        | description : String
        , tag : String
        , period : String
        , block : Maybe HabitId
    }


editPageFromHabit : Habit -> Page
editPageFromHabit habit =
    EditHabit
        { id = habit.id
        , description = habit.description
        , tag = habit.tag
        , period = Period.toString habit.period
        , block = Habit.getBlocker habit
        }


type alias NewPage =
    { description : String
    , tag : String
    , period : String
    , block : Maybe HabitId
    }


newNewPage : Page
newNewPage =
    NewHabit
        { description = ""
        , tag = ""
        , period = "1 Day"
        , block = Nothing
        }


type alias OptionsPage =
    { recent : String
    , upcoming : String
    }


optionsPageFromOptions : Options -> Page
optionsPageFromOptions options =
    ChangeOptions
        { recent = Period.toString options.recent
        , upcoming = Period.toString options.upcoming
        }


type alias Options =
    { recent : Period
    , upcoming : Period
    }


defaultOptions =
    { recent = Hours 12
    , upcoming = Hours 12
    }



-- SUBSCRIPTIONS


animationSubscription : Model -> Sub Msg
animationSubscription model =
    Animation.subscription
        AnimatePage
        (List.map
            (\(Transition m) -> m.style)
            (Store.values model.pageTransitions)
        )


timeSubscription : Model -> Sub Msg
timeSubscription model =
    Time.every 1000 Tick


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch [ timeSubscription model, animationSubscription model ]



-- PORTS


port store : JE.Value -> Cmd msg


storeModel : ( Model, Cmd msg ) -> ( Model, Cmd msg )
storeModel ( model, cmd ) =
    ( model, Cmd.batch [ cmd, store (storageEncoder model) ] )



-- UPDATE


type PageUpdate
    = ChangeEditDescription String
    | ChangeEditTag String
    | ChangeEditPeriod String
    | ToggleEditBlocked
    | ChangeEditBlocked HabitId
    | ChangeNewDescription String
    | ChangeNewTag String
    | ChangeNewPeriod String
    | ToggleNewBlocked
    | ChangeNewBlocked HabitId
    | ChangeOptionsRecent String
    | ChangeOptionsUpcoming String


type Msg
    = NoOp
    | NoOps String
      -- Subscriptions
    | Tick Time.Posix
    | AnimatePage Animation.Msg
    | SwapPages String
    | ClearTransition String
      -- Pages
    | OpenEditPage HabitId
    | OpenNewPage
    | OpenOptionsPage
    | OpenHabitListPage Int
    | UpdatePage PageUpdate
      -- Options
    | SaveOptions OptionsPage
      -- Tasks
    | DoHabit HabitId
    | DoAddHabit NewPage
    | DoDeleteHabit HabitId
    | DoEditHabit EditPage


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

        AnimatePage animMsg ->
            let
                transMap =
                    Store.mapValues
                        (\(Transition transition) ->
                            let
                                ( style, cmd ) =
                                    Animation.Messenger.update animMsg transition.style
                            in
                            ( Transition { transition | style = style }, cmd )
                        )
                        model.pageTransitions

                cmds =
                    Store.values transMap
                        |> List.map Tuple.second

                newTransitions =
                    Store.mapValues (\t -> Tuple.first t) transMap
            in
            ( { model | pageTransitions = newTransitions }, Cmd.batch cmds )

        SwapPages index ->
            ( { model
                | pageTransitions =
                    Store.update index (\(Transition t) -> Transition { t | above = False }) model.pageTransitions
              }
            , Cmd.none
            )

        ClearTransition index ->
            ( { model
                | pageTransitions = Store.delete index model.pageTransitions
              }
            , Cmd.none
            )

        OpenHabitListPage pageNumber ->
            ( openHabitListPage pageNumber model, Cmd.none )

        OpenEditPage habitId ->
            let
                maybeHabit =
                    Store.get habitId model.habits
            in
            case maybeHabit of
                Nothing ->
                    ( model, Cmd.none )

                Just habit ->
                    ( { model
                        | page = editPageFromHabit habit
                        , pageTransitions = Store.insert (openPageTransition model) model.pageTransitions
                      }
                    , Cmd.none
                    )

        OpenNewPage ->
            ( { model
                | page = newNewPage
                , pageTransitions = Store.insert (openPageTransition model) model.pageTransitions
              }
            , Cmd.none
            )

        OpenOptionsPage ->
            ( { model
                | page = optionsPageFromOptions model.options
                , pageTransitions = Store.insert (openPageTransition model) model.pageTransitions
              }
            , Cmd.none
            )

        SaveOptions optionsFields ->
            let
                options =
                    model.options

                updatedOptions =
                    { options
                        | recent = Period.parse optionsFields.recent
                        , upcoming = Period.parse optionsFields.upcoming
                    }
            in
            ( { model | options = updatedOptions } |> openHabitList
            , Cmd.none
            )
                |> storeModel

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

        DoAddHabit fields ->
            case fields.description of
                "" ->
                    ( model |> openHabitList, Cmd.none )

                _ ->
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
                      }
                        |> openHabitList
                    , Cmd.none
                    )
                        |> storeModel

        DoDeleteHabit habitId ->
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
              }
                |> openHabitList
            , Cmd.none
            )
                |> storeModel

        DoEditHabit editPage ->
            ( { model
                | habits =
                    Store.filterIds ((==) editPage.id) model.habits
                        |> Store.mapValues
                            (\habit ->
                                { habit
                                    | description = editPage.description
                                    , tag = editPage.tag
                                    , period = Period.parse editPage.period
                                    , block =
                                        case ( editPage.block, habit.block ) of
                                            ( Nothing, _ ) ->
                                                Habit.Unblocked

                                            ( Just hid, Habit.Blocker _ isBlocked ) ->
                                                Habit.Blocker hid isBlocked

                                            ( Just hid, _ ) ->
                                                Habit.Blocker hid False
                                }
                            )
                        |> Store.union model.habits
              }
                |> openHabitList
            , Cmd.none
            )
                |> storeModel

        UpdatePage pageUpdate ->
            case ( pageUpdate, model.page ) of
                ( ChangeEditDescription str, EditHabit page ) ->
                    ( { model | page = EditHabit { page | description = str } }
                    , Cmd.none
                    )

                ( ChangeEditTag str, EditHabit page ) ->
                    ( { model | page = EditHabit { page | tag = str } }
                    , Cmd.none
                    )

                ( ChangeEditPeriod str, EditHabit page ) ->
                    ( { model | page = EditHabit { page | period = str } }
                    , Cmd.none
                    )

                ( ToggleEditBlocked, EditHabit page ) ->
                    ( -- TODO Get an actual HabitId for this.
                      { model
                        | page =
                            EditHabit
                                { page
                                    | block =
                                        case page.block of
                                            Nothing ->
                                                Just ""

                                            Just _ ->
                                                Nothing
                                }
                      }
                    , Cmd.none
                    )

                ( ChangeEditBlocked habitId, EditHabit page ) ->
                    ( { model | page = EditHabit { page | block = Just habitId } }
                    , Cmd.none
                    )

                ( ChangeNewDescription str, NewHabit page ) ->
                    ( { model | page = NewHabit { page | description = str } }
                    , Cmd.none
                    )

                ( ChangeNewTag str, NewHabit page ) ->
                    ( { model | page = NewHabit { page | tag = str } }
                    , Cmd.none
                    )

                ( ChangeNewPeriod str, NewHabit page ) ->
                    ( { model | page = NewHabit { page | period = str } }
                    , Cmd.none
                    )

                ( ToggleNewBlocked, NewHabit page ) ->
                    ( -- TODO Get an actual HabitId for this.
                      { model
                        | page =
                            NewHabit
                                { page
                                    | block =
                                        case page.block of
                                            Nothing ->
                                                Just ""

                                            Just _ ->
                                                Nothing
                                }
                      }
                    , Cmd.none
                    )

                ( ChangeNewBlocked habitId, NewHabit page ) ->
                    ( { model | page = NewHabit { page | block = Just habitId } }
                    , Cmd.none
                    )

                ( ChangeOptionsRecent str, ChangeOptions page ) ->
                    ( { model | page = ChangeOptions { page | recent = str } }
                    , Cmd.none
                    )

                ( ChangeOptionsUpcoming str, ChangeOptions page ) ->
                    ( { model | page = ChangeOptions { page | upcoming = str } }
                    , Cmd.none
                    )

                ( _, _ ) ->
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


openHabitListPage : Int -> Model -> Model
openHabitListPage pageNum model =
    let
        page =
            HabitList { pageNumber = pageNum }
    in
    { model | page = page, pageTransitions = Store.insert (openPageTransition model) model.pageTransitions }


openHabitList =
    openHabitListPage 0



-- VIEW


view : Model -> Html Msg
view model =
    div
        [ class "page-container" ]
        [ maybeViewTransition model
        , div
            [ class "middle" ]
            [ viewPage model model.page ]
        ]


maybeViewTransition : Model -> Html Msg
maybeViewTransition model =
    div
        []
        (List.map
            (viewPageTransition model)
            (Store.values model.pageTransitions)
        )


viewPageTransition : Model -> PageTransition -> Html Msg
viewPageTransition model (Transition transition) =
    let
        -- TODO Z value should depend on indez
        classes =
            if transition.above then
                [ class "transition-page", class "above" ]

            else
                [ class "transition-page", class "below" ]
    in
    div
        (classes ++ Animation.render transition.style)
        [ view
            transition.previous
        ]


viewPage : Model -> Page -> Html Msg
viewPage model page =
    case page of
        HabitList habitList ->
            viewHabitsListPage model habitList

        EditHabit editPage ->
            viewEditingPage model editPage

        NewHabit newPage ->
            viewNewPage model newPage

        ChangeOptions optionsPage ->
            viewOptionsPage model optionsPage



-- HABITS VIEW


viewHabitsListPage : Model -> HabitListPage -> Html Msg
viewHabitsListPage model habits =
    div
        [ class "page" ]
        [ div
            [ class "page-head" ]
            [ div
                [ class "margin" ]
                [ button
                    [ class "add-habit", onClick OpenOptionsPage ]
                    [ text "-" ]
                ]
            ]
        , viewHabits model habits.pageNumber
        , div [ class "page-foot" ] []
        ]


viewHabits : Model -> Int -> Html Msg
viewHabits model pageNumber =
    -- TODO handle multiple pages of habits
    let
        { pageLines, time, options, habits } =
            model

        visible =
            visibleHabits model
                |> Store.values
                |> List.sortBy (habitOrderer model)
                |> List.drop (pageNumber * model.pageLines)
                |> List.take model.pageLines
    in
    div
        []
        (List.map (viewHabitLine model) visible
            ++ viewLine
                (button
                    [ class "add-habit", onClick OpenNewPage ]
                    [ text "+" ]
                )
                emptyDiv
            :: (List.range (List.length visible) (pageLines - 1)
                    |> List.map emptyLine
               )
        )


viewHabitLine : Model -> Habit -> Html Msg
viewHabitLine model habit =
    viewLine
        (button
            [ class "habit-edit"
            , onClick (OpenEditPage habit.id)
            ]
            [ text "..." ]
        )
        (button
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


viewEditingPage : Model -> EditPage -> Html Msg
viewEditingPage model fields =
    div
        [ class "page" ]
        ([ div [ class "page-head" ] []
         , habitFieldsView
            fields
            (Store.values model.habits)
            (Just fields.id)
            (\s -> UpdatePage (ChangeEditDescription s))
            (\s -> UpdatePage (ChangeEditTag s))
            (\s -> UpdatePage (ChangeEditPeriod s))
            (UpdatePage ToggleEditBlocked)
            (\h -> UpdatePage (ChangeEditBlocked h))
         , viewLineContent
            (div
                [ class "button-line" ]
                [ button [ onClick (DoEditHabit fields) ] [ text "Save" ]
                , button [ onClick (DoDeleteHabit fields.id) ] [ text "Delete" ]
                , button [ onClick (OpenHabitListPage 0) ] [ text "Cancel" ]
                ]
            )
         ]
            ++ (List.range 8 (model.pageLines - 1) |> List.map emptyLine)
            ++ [ div [ class "page-foot" ] [] ]
        )



-- NEW VIEW


viewNewPage : Model -> NewPage -> Html Msg
viewNewPage model fields =
    div
        [ class "page" ]
        ([ div [ class "page-head" ] []
         , habitFieldsView
            fields
            (Store.values model.habits)
            Nothing
            (\s -> UpdatePage (ChangeNewDescription s))
            (\s -> UpdatePage (ChangeNewTag s))
            (\s -> UpdatePage (ChangeNewPeriod s))
            (UpdatePage ToggleNewBlocked)
            (\h -> UpdatePage (ChangeNewBlocked h))
         , viewLineContent
            (div
                [ class "button-line" ]
                [ button [ onClick (DoAddHabit fields) ] [ text "Save" ]
                , button [ onClick (OpenHabitListPage 0) ] [ text "Cancel" ]
                ]
            )
         ]
            ++ (List.range 8 (model.pageLines - 1) |> List.map emptyLine)
            ++ [ div [ class "page-foot" ] [] ]
        )



-- OPTIONS VIEW


viewOptionsPage : Model -> OptionsPage -> Html Msg
viewOptionsPage model fields =
    div
        [ class "page" ]
        ([ div [ class "page-head" ]
            [ div
                [ class "margin" ]
                [ button
                    [ class "add-habit", onClick OpenOptionsPage ]
                    [ text "-" ]
                ]
            ]
         ]
            ++ [ viewLineContent (label [] [ text "Show upcoming" ])
               , viewLineContent
                    (input
                        [ value fields.upcoming, list "upcoming-list", onInput (\s -> UpdatePage (ChangeOptionsUpcoming s)) ]
                        []
                    )
               , viewLineContent (label [] [ text "Show recently done" ])
               , viewLineContent
                    (input
                        [ value fields.recent, list "recent-list", onInput (\s -> UpdatePage (ChangeOptionsRecent s)) ]
                        []
                    )
               , viewLineContent
                    (div
                        [ class "button-line" ]
                        [ button [ onClick (SaveOptions fields) ] [ text "Save" ]
                        , button [ onClick (OpenHabitListPage 0) ] [ text "Cancel" ]
                        ]
                    )
               ]
            ++ (List.range 4 (model.pageLines - 1) |> List.map emptyLine)
            ++ [ div [ class "page-foot" ] []
               , periodOptionsView fields.upcoming "upcoming-list"
               , periodOptionsView fields.recent "recent-list"
               ]
        )



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


maybeToBool : Maybe a -> Bool
maybeToBool m =
    case m of
        Nothing ->
            False

        Just _ ->
            True


onChange : (HabitId -> msg) -> Attribute msg
onChange handler =
    on "change" (changeDecoder handler)


changeDecoder2 handler i =
    JD.succeed (handler i)


changeDecoder : (HabitId -> msg) -> JD.Decoder msg
changeDecoder handler =
    JD.at [ "target", "value" ] JD.string
        |> JD.andThen (changeDecoder2 handler)


habitSelectorOption : HabitId -> Habit -> Html Msg
habitSelectorOption selectedHabit habit =
    option
        [ value habit.id
        , Html.Attributes.selected (selectedHabit == habit.id)
        ]
        [ text habit.description ]


habitSelector : List Habit -> Maybe HabitId -> (HabitId -> Msg) -> Html Msg
habitSelector habits selected change =
    select
        [ onChange change, disabled (not (maybeToBool selected)) ]
        (case selected of
            Nothing ->
                []

            Just habitId ->
                List.map (habitSelectorOption habitId) habits
        )



-- TODO FIX THIS


habitFieldsView :
    HabitFields a
    -> List Habit
    -> Maybe HabitId
    -> (String -> Msg)
    -> (String -> Msg)
    -> (String -> Msg)
    -> Msg
    -> (HabitId -> Msg)
    -> Html Msg
habitFieldsView fields habits maybeHabit descChange tagChange periodChange toggleBlock blockChange =
    let
        tagOption tag =
            option [ value tag ] [ text tag ]

        tagOptions =
            List.map .tag habits |> List.map tagOption

        filteredHabits =
            case maybeHabit of
                Nothing ->
                    habits

                Just habitId ->
                    List.filter (\h -> habitId /= h.id) habits

        canBeBlocked =
            not (List.isEmpty filteredHabits)
    in
    Html.form
        []
        ([ asLineContent label
            []
            [ text "I want to" ]
         , asLineContent input
            [ placeholder "Do Something", value fields.description, onInput descChange ]
            []
         , asLineContent label
            []
            [ text "every" ]
         , asLineContent input
            [ placeholder "Period", value fields.period, list "period-list", onInput periodChange ]
            []
         ]
            ++ (if canBeBlocked then
                    [ asLineContent div
                        [ class "fuckaround" ]
                        [ input [ type_ "checkbox", onClick toggleBlock, checked (maybeToBool fields.block) ] []
                        , label [] [ text "after doing" ]
                        ]
                    , viewLineContent (habitSelector filteredHabits fields.block blockChange)
                    ]

                else
                    []
               )
            ++ [ asLineContent label
                    []
                    [ text "Tag" ]
               , asLineContent input
                    [ placeholder "Todo", value fields.tag, list "tag-list", onInput tagChange ]
                    []
               , datalist
                    [ id "tag-list" ]
                    tagOptions
               , periodOptionsView fields.period "period-list"
               ]
            ++ (if canBeBlocked then
                    []

                else
                    [ viewLineContent emptyDiv, viewLineContent emptyDiv ]
               )
        )



-- Line helpers


emptyDiv =
    div [] []


viewLine : Html Msg -> Html Msg -> Html Msg
viewLine margin line =
    div
        [ class "page-line" ]
        [ div
            [ class "margin" ]
            [ margin ]
        , div
            [ class "line-content" ]
            [ line ]
        ]


viewLineContent : Html Msg -> Html Msg
viewLineContent line =
    viewLine emptyDiv line


asLineContent : (b -> c -> Html Msg) -> b -> c -> Html Msg
asLineContent el attribs children =
    viewLine emptyDiv (el attribs children)


emptyLine : a -> Html Msg
emptyLine a =
    viewLine emptyDiv emptyDiv



-- Due Helpers


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



-- Encode/Decode


defaultStorageModel : StorageModel
defaultStorageModel =
    StorageModel defaultOptions (Store.empty Store.RandomId) 0


habitDictFromList : List Habit -> Dict HabitId Habit
habitDictFromList habits =
    List.map (\h -> ( h.id, h )) habits
        |> Dict.fromList


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



-- UTILS


flip : (a -> b -> c) -> b -> a -> c
flip fn b a =
    fn a b


curry : (( a, b ) -> c) -> a -> b -> c
curry fn a b =
    fn ( a, b )


uncurry : (a -> b -> c) -> ( a, b ) -> c
uncurry fn ( a, b ) =
    fn a b
