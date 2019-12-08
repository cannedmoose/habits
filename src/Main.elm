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
import Store exposing (SimpleStore, Store)
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
        storage =
            JD.decodeValue storageDecoder flags.model
                |> Result.withDefault defaultStorageModel

        time =
            Time.millisToPosix flags.time
    in
    ( { time = time
      , habits = storage.habits
      , options = storage.options
      , uuid = storage.uuid
      , page = HabitList { pageNumber = 0 }
      , pageTransitions = Store.simpleStore
      , pageLines = 20
      }
    , Cmd.none
    )



-- MODEL


type alias Flags =
    { time : Int, model : JD.Value }


type alias StorageModel =
    { uuid : Int
    , options : Options
    , habits : Dict HabitId Habit
    }


type alias Model =
    { time : Posix
    , habits : Dict HabitId Habit
    , options : Options
    , page : Page
    , pageTransitions : SimpleStore PageTransition
    , uuid : Int
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
        , block =
            case habit.block of
                Habit.BlockedBy id ->
                    Just id

                Habit.UnblockedBy id ->
                    Just id

                _ ->
                    Nothing
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
    | SwapPages Int
    | ClearTransition Int
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
                    Dict.get habitId model.habits
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
            ( { model
                | habits = Habit.do model.time model.habits habitId
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
                                model.uuid
                                (Period.parse fields.period)
                                fields.block
                    in
                    ( { model
                        | habits = Dict.insert newHabit.id newHabit model.habits
                        , uuid = model.uuid + 1
                      }
                        |> openHabitList
                    , Cmd.none
                    )
                        |> storeModel

        DoDeleteHabit habitId ->
            ( { model
                | habits =
                    Dict.remove habitId model.habits
                        |> Dict.map
                            (\id habit ->
                                case habit.block of
                                    Habit.Unblocked ->
                                        habit

                                    Habit.BlockedBy id2 ->
                                        if id2 == habitId then
                                            { habit | block = Habit.Unblocked }

                                        else
                                            habit

                                    Habit.UnblockedBy id2 ->
                                        if id2 == habitId then
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
                    Dict.update
                        editPage.id
                        (Maybe.map
                            (\h ->
                                { h
                                    | description = editPage.description
                                    , tag = editPage.tag
                                    , period = Period.parse editPage.period
                                    , block =
                                        case ( editPage.block, h.block ) of
                                            ( Nothing, _ ) ->
                                                Habit.Unblocked

                                            ( Just hid, Habit.BlockedBy _ ) ->
                                                Habit.BlockedBy hid

                                            ( Just hid, _ ) ->
                                                Habit.UnblockedBy hid
                                }
                            )
                        )
                        model.habits
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
                                                Just 0

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
                                                Just 0

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


visibleHabits : Model -> Dict HabitId Habit
visibleHabits model =
    Dict.filter (\_ -> viewHabitFilter model) model.habits


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
                |> Dict.toList
                |> List.sortBy (\( id, h ) -> habitOrderer model h)
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


viewHabitLine : Model -> ( HabitId, Habit ) -> Html Msg
viewHabitLine model ( habitId, habit ) =
    viewLine
        (button
            [ class "habit-edit"
            , onClick (OpenEditPage habitId)
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
            , onClick (DoHabit habitId)
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
            (Dict.values model.habits)
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
            (Dict.values model.habits)
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
    let
        hid =
            Maybe.withDefault 0 (String.toInt i)
    in
    JD.succeed (handler hid)


changeDecoder : (HabitId -> msg) -> JD.Decoder msg
changeDecoder handler =
    JD.at [ "target", "value" ] JD.string
        |> JD.andThen (changeDecoder2 handler)


habitSelectorOption : HabitId -> Habit -> Html Msg
habitSelectorOption selectedHabit habit =
    option
        [ value (String.fromInt habit.id)
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
    posixToMillis (Habit.nextDue habit)
        < posixToMillis (addToPosix options.upcoming time)


isRecentlyDone : Model -> Habit -> Bool
isRecentlyDone { time, options } habit =
    Habit.lastDone habit
        |> Maybe.map (\l -> posixToMillis l > posixToMillis (minusFromPosix options.recent time))
        |> Maybe.withDefault False


shouldBeMarkedAsDone : Model -> Habit -> Bool
shouldBeMarkedAsDone model habit =
    let
        due =
            isDueSoon model habit
    in
    case habit.block of
        Habit.Unblocked ->
            not due

        Habit.UnblockedBy hid ->
            not due

        Habit.BlockedBy hid ->
            True


viewHabitFilter : Model -> Habit -> Bool
viewHabitFilter model habit =
    let
        due =
            isDueSoon model habit

        recent =
            isRecentlyDone model habit
    in
    case habit.block of
        Habit.Unblocked ->
            due || recent

        Habit.UnblockedBy hid ->
            due || recent

        Habit.BlockedBy hid ->
            recent



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
        { previous = { model | pageTransitions = Store.simpleStore }
        , style = pageTransitionStyle model initalPageTransitionStyle
        , above = True
        }



-- Encode/Decode


defaultStorageModel : StorageModel
defaultStorageModel =
    StorageModel 0 defaultOptions Dict.empty


habitDictFromList : List Habit -> Dict HabitId Habit
habitDictFromList habits =
    List.map (\h -> ( h.id, h )) habits
        |> Dict.fromList


storageDecoder : JD.Decoder StorageModel
storageDecoder =
    JD.map3 StorageModel
        (JD.field "uuid" JD.int)
        (JD.field "options" optionsDecoder)
        (JD.field "habits"
            (JD.map
                habitDictFromList
                (JD.list Habit.decoder)
            )
        )


storageEncoder : Model -> JE.Value
storageEncoder model =
    JE.object
        [ ( "uuid", JE.int model.uuid )
        , ( "options", optionsEncoder model.options )
        , ( "habits", JE.list Habit.encode (Dict.values model.habits) )
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
