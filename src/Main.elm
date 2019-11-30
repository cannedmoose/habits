port module Main exposing (..)

import Animation
import Animation.Messenger
import Browser
import Habit exposing (Habit)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Html.Events exposing (..)
import Parser
import Period exposing (Period(..), addToPosix, minusFromPosix)
import Time exposing (Posix, posixToMillis)

-- TODO figure out why we can't import this...
rgba r g b a=
    { red = r
    , green = g
    , blue = b
    , alpha = a
    }

type alias Flags = {time : Int}

main : Program Flags Model Msg
main =
    Browser.document
        { init = init
        , view = \model -> { title = "Tasks", body = [view model] }
        , update = update
        , subscriptions = subscriptions
        }

init : Flags -> ( Model, Cmd Msg )
init flags =
    ({ time = Time.millisToPosix flags.time
     , habits = []
     , slots = []
     , options = defaultOptions
     , modal = Nothing
     , uuid = 0
    }, Cmd.none)

-- MODEL
type alias Model = 
    { time : Posix 
    , habits : List Habit
    , slots : List Slot
    , options : Options
    , modal : Maybe ModalTransition
    , uuid : Int
    }

type Modal
    = Editing EditModal
    | NewHabit NewModal
    | ChangeOptions OptionsModal

type alias ModalTransition =
    { modal: Modal
    , background: Anim
    , content: Anim
    }
openModalTransition : Modal -> ModalTransition
openModalTransition modal =
    { modal = modal
    , background = (Animation.interrupt [ Animation.to [ Animation.backgroundColor (rgba 0 0 0 0.4 ) ] ] initalBgStyle)
    , content = (Animation.interrupt [ Animation.to [ Animation.top (Animation.px 0)] ] initalContentStyle)
    }

type alias EditModal =
    { id: Habit.Id
    , description: String
    , tag: String
    , period: String
    }
editModalFromHabit : Habit -> Modal
editModalFromHabit habit =
    Editing
    { id = habit.id
    , description = habit.description
    , tag = habit.tag
    , period = Period.toString(habit.period) 
    }

type alias NewModal =
    { description: String
    , tag: String
    , period: String
    }
newNewModal : Modal
newNewModal =
    NewHabit 
    { description = ""
    , tag = ""
    , period = "" 
    }

type alias OptionsModal =
    { recent: String
    , upcoming: String
    }
optionsModalFromOptions : Options -> Modal
optionsModalFromOptions options =
    ChangeOptions
        { recent = Period.toString(options.recent) 
        , upcoming = Period.toString(options.upcoming) 
        }

{-
Note: Slot stores habit state so we can do a clean slide even if a habit has been updated 
-}
type alias Slot
    = { style : Anim
        , habits: OR Habit Habit
        }

type alias Options =
    { recent : Period
    , upcoming : Period
    }
defaultOptions = 
    { recent = Hours 12
    ,upcoming = Hours 12
    }

type alias Anim = Animation.Messenger.State Msg

-- SUBSCRIPTIONS

animationSubscription : Model -> Sub Msg
animationSubscription model =
    case model.modal of
        Just m -> (Animation.subscription AnimateModal [ m.background, m.content ])
        Nothing -> (Sub.none)

slotSubscription : Model -> Sub Msg
slotSubscription model =
    Animation.subscription AnimateSlot (List.map .style model.slots)

timeSubscription : Model -> Sub Msg
timeSubscription model = Sub.none
  -- Time.every 1000 Tick

subscriptions : Model -> Sub Msg
subscriptions model =
  Sub.batch [timeSubscription model, animationSubscription model, slotSubscription model]

-- PORTS
port storeTasks : {} -> Cmd msg
store : Model -> Cmd Msg -> (Model, Cmd Msg)
store model cmd = (model, cmd)

-- UPDATE
type ModalUpdate
    = ChangeEditDescription String
    | ChangeEditTag String
    | ChangeEditPeriod String
    | ChangeNewDescription String
    | ChangeNewTag String
    | ChangeNewPeriod String
    | ChangeOptionsRecent String
    | ChangeOptionsUpcoming String

type Msg 
    = NoOp
    | NoOps String

    -- Subscriptions
    | Tick Time.Posix
    | AnimateModal Animation.Msg
    | RemoveModal
    | AnimateSlot Animation.Msg
    | RemoveSlots

    -- Modals
    | OpenEditModal Habit.Id
    | OpenNewModal
    | OpenOptionsModal
    | CloseModal
    | UpdateModal ModalUpdate

    -- Options
    | SaveOptions OptionsModal

    -- Tasks
    | DoHabit Habit.Id
    | AddHabit NewModal
    | DeleteHabit Habit.Id
    | EditHabit EditModal

initalBgStyle = (Animation.style [ Animation.backgroundColor (rgba 0 0 0 0.0 ) ])
initalContentStyle = (Animation.style [ Animation.top (Animation.px -800) ])
closeBgStyle = Animation.interrupt
        [ Animation.to [ Animation.backgroundColor (rgba 0 0 0 0.0) ]
        , Animation.Messenger.send (RemoveModal)
        ]
closeContentStyle = Animation.interrupt
        [ Animation.to [ Animation.top (Animation.px -300) ]
        ]

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NoOp -> (model, Cmd.none)
        NoOps s -> (model, Cmd.none)

        Tick time ->
            (
                { model | time = time } |> fillSlots
                , Cmd.none
            )

        AnimateModal animMsg ->
            case model.modal of
            Nothing -> (model, Cmd.none)
            Just modal -> ( 
                let
                    updateStyle s = Animation.Messenger.update animMsg s
                    (background, cmd1) = updateStyle modal.background
                    (content, cmd2) = updateStyle modal.content
                in
                ( { model | modal = Just {modal | background = background, content = content} }
                , (Cmd.batch [cmd1, cmd2])
                )
                )
        
        RemoveModal ->
            (
                let 
                    modal = model.modal
                in
                    ( {model | modal = Nothing }
                    , Cmd.none
                    )
            )

        AnimateSlot animMsg ->
            (
                let
                    updateStyle s = Animation.Messenger.update animMsg s
                    (slotStyles, slotCmds) = List.map .style model.slots 
                        |> List.map updateStyle
                        |> List.unzip
                in
                    ({model
                    | slots = List.map2 
                        (\slot style -> {slot | style = style})
                        model.slots
                        slotStyles
                    }, Cmd.batch(slotCmds))
            )
        
        -- TODO IMPLEMENT Figure out how to call
        RemoveSlots ->
            (
                let
                    _ = Debug.log "REMOVE" "YEAH"
                in
                    ( model, Cmd.none )
            )
        
        OpenEditModal habitId ->
            (
                let
                    habit = List.filter (\h -> h.id == habitId) model.habits
                        |> List.head
                    modal = Maybe.map editModalFromHabit habit
                        |> Maybe.map openModalTransition
                in
                { model | modal = modal }, Cmd.none
            )
        
        OpenNewModal ->
            (
                let
                    modal = openModalTransition newNewModal
                in
                { model | modal = Just modal }, Cmd.none
            )
        
        OpenOptionsModal ->
            (
                let
                    modal = openModalTransition (optionsModalFromOptions model.options)
                in
                { model | modal = Just modal }, Cmd.none
            )

        CloseModal ->
            (
                model |> closeModal, Cmd.none
            )

        SaveOptions optionsFields ->
            let
                options = model.options
                updatedOptions =
                    { options 
                    | recent = (Period.parse optionsFields.recent)
                    , upcoming = (Period.parse optionsFields.upcoming)
                    }
            in
                ( { model | options = updatedOptions } |> fillSlots |> closeModal
                , Cmd.none
                )

        DoHabit habitId ->
            (
                let
                    updatedHabits = List.map 
                        (\h -> 
                            if h.id == habitId
                            then Habit.do model.time h 
                            else h
                        ) 
                        model.habits
                in
                    {
                        model | habits = updatedHabits
                    } |> fillSlots
                    , Cmd.none
            )
        
        AddHabit fields ->
            let
                newHabit = Habit.newHabit
                    model.time
                    fields.description
                    fields.tag
                    (Habit.HabitId model.uuid)
                    (Period.parse fields.period)
            in
                (
                    { model | habits = newHabit :: model.habits
                    , uuid = (model.uuid + 1) } |> closeModal |> fillSlots
                    , Cmd.none
                )
        
        DeleteHabit habitId ->
            (
                { model 
                | habits = List.filter (\h -> (Habit.id h) /= habitId) model.habits
                } |> closeModal |> fillSlots
                , Cmd.none
            )
        
        EditHabit editModal ->
            (
                let
                    updatedHabits = List.map 
                        (\h -> 
                            if h.id == editModal.id
                            then
                                {h | description = editModal.description, tag = editModal.tag, period = (Period.parse editModal.period)} 
                            else h
                        ) 
                        model.habits
                in
                    {
                        model | habits = updatedHabits 
                    } |> closeModal |> fillSlots , Cmd.none
            )

        UpdateModal modalUpdate -> (
            case model.modal of
                Nothing -> (model, Cmd.none)
                Just transition -> (
                    case (modalUpdate, transition.modal) of
                        (ChangeEditDescription str, Editing modal) ->
                            (
                                {model | modal = Just {transition | modal = Editing {modal | description = str}}}, Cmd.none 
                            )
                        (ChangeEditTag str, Editing modal) ->
                            (
                                {model | modal = Just {transition | modal = Editing {modal | tag = str}}}, Cmd.none 
                            )
                        (ChangeEditPeriod str, Editing modal) ->
                            (
                                {model | modal = Just {transition | modal = Editing {modal | period = str}}}, Cmd.none 
                            )
                        (ChangeNewDescription str, NewHabit modal) ->
                            (
                                {model | modal = Just {transition | modal = NewHabit {modal | description = str}}}, Cmd.none 
                            )
                        (ChangeNewTag str, NewHabit modal) ->
                            (
                                {model | modal = Just {transition | modal = NewHabit {modal | tag = str}}}, Cmd.none 
                            )
                        (ChangeNewPeriod str, NewHabit modal) ->
                            (
                                {model | modal = Just {transition | modal = NewHabit {modal | period = str}}}, Cmd.none 
                            )
                        (ChangeOptionsRecent str, ChangeOptions modal) ->
                            (
                                {model | modal = Just {transition | modal = ChangeOptions {modal | recent = str}}}, Cmd.none 
                            )
                        (ChangeOptionsUpcoming str, ChangeOptions modal) ->
                            (
                                {model | modal = Just {transition | modal = ChangeOptions {modal | upcoming = str}}}, Cmd.none 
                            )
                        (_, _) -> (model, Cmd.none)
                    )
            )
        

slotSlideStart = (Animation.style [ Animation.left (Animation.px -800) ])
slotSlideEnd index = [ 
    Animation.wait (Time.millisToPosix (index * 400)),
    Animation.to [ Animation.left (Animation.px 0) ]
    ]
slotFinale = [Animation.Messenger.send RemoveSlots]

fillSlot : Int -> OR Slot Habit -> (Int, Slot)
fillSlot accum slotOrHabit =
    case slotOrHabit of
        Both slot habit ->
            let
                currentHabit = case slot.habits of
                    Both f s -> Just f
                    First f -> Just f
                    _ -> Nothing
                {-
                    TODO work out if this is the same based on visible properties
                    ATM it's just id, want it to slide through if description changed though
                -}
                sameHabit = Maybe.map (\c -> c.id == habit.id) currentHabit
                    |> Maybe.withDefault False
            in
                if sameHabit then
                    (accum, { slot | habits = First habit})
                else
                    (accum + 1
                    , Slot
                        (Animation.interrupt (slotSlideEnd accum) slotSlideStart)
                        (Maybe.map (\c -> Both habit c) currentHabit
                            |> Maybe.withDefault (First habit))
                    )
        First slot -> (
            let
                sameHabit = case slot.habits of
                    Second s -> True
                    _ -> False
            in
                if sameHabit then
                    (accum, slot)
                else
                    (accum + 1
                    , Slot
                        (Animation.interrupt (slotSlideEnd accum) slotSlideStart)
                        (case slot.habits of
                            Both f s -> Second f
                            Second s -> Second s
                            First f -> Second f)
                    )
            )
        Second habit -> (
            accum + 1,
            Slot
                (Animation.interrupt (slotSlideEnd accum) slotSlideStart)
                (First habit)
            )

fillSlots : Model -> Model
fillSlots model =
    let
        recentlyDone = isRecentlyDone model.time model.options
        dueSoon = isDueSoon model.time model.options
        isVisible task = (dueSoon task) || (recentlyDone task)
        visibleHabits = (List.sortBy (\h -> Time.posixToMillis h.nextDue) (List.filter isVisible model.habits))
        newSlots = foldlMap fillSlot 0 (zip model.slots visibleHabits)
    in
        {model | slots = newSlots}

closeModal : Model -> Model
closeModal model =
    let
        modalTransition = Maybe.map
            (\modal -> {modal | background = closeBgStyle modal.background, content = closeContentStyle modal.content})
            model.modal
    in
    { model | modal = modalTransition }

type OR a b
    = Both a b
    | First a
    | Second b

-- Zip that doesnt drop items
zip : List a -> List b -> List (OR a b)
zip a b =
    case a of
        aitem :: arest ->
            case b of
                bitem :: brest ->
                    (Both aitem bitem :: zip arest brest)
                _ -> (First aitem) :: zip arest []
        _ ->
            case b of
                bitem :: brest ->
                    ((Second bitem) :: zip [] brest)
                _ -> []

{- Fold a value left while mapping a function and passing the value in-}
foldlMap : (b -> a -> (b, c)) -> b -> List a -> List c
foldlMap fn initial l =
    case l of
        [] -> ([])
        val :: rest -> 
            ( let
                (accum, r) = fn initial val 
            in
                r :: (foldlMap fn accum rest)
            ) 

-- VIEW
emptyDiv = (div [] [])

view : Model -> Html Msg
view model =
    div
        [class "page"]
        [ maybeViewModal model
        , viewMenu model
        , viewHabitList model
        ]

viewMenu : Model -> Html Msg
viewMenu model =
    section
        [ class "menu" ]
        [
            button
                [ class "add-task", onClick (OpenNewModal) ]
                [ text "+" ]
            , button
                [ class "add-task", onClick (OpenOptionsModal) ]
                [ text "O" ]
        ]

maybeViewModal: Model -> Html Msg
maybeViewModal model =
    Maybe.map
        (viewModalTransition model)
        model.modal |>
        Maybe.withDefault emptyDiv

viewModalTransition : Model -> ModalTransition -> Html Msg
viewModalTransition model transition =
    div
        (class "modal-background" :: Animation.render transition.background)
        [ div
            (class "modal-content" :: Animation.render transition.content)
            [ viewModal model transition.modal]
        ]

viewModal : Model -> Modal -> Html Msg
viewModal model modal =
    case modal of
        Editing editModal ->
                (viewEditingModal editModal model.habits)
        NewHabit newModal ->
                (viewNewModal newModal model.habits)
        ChangeOptions optionsModal ->
                (viewOptionsModal optionsModal)

periodOptionsView : String -> String -> Html Msg
periodOptionsView input for =
    let
        periodUnit = Result.withDefault 
                1
                (Parser.run Parser.int input)
        periodOption period =
            option
                [value (Period.toString period)]
                [text (Period.toString period)]
        periodOptions unit =
            [ periodOption (Minutes unit)
            , periodOption (Hours unit)
            , periodOption (Days unit)
            , periodOption (Weeks unit)
            , periodOption (Months unit)
            ]  
    in
        datalist
            [id for]
            ((periodOptions periodUnit) ++ (periodOptions (periodUnit + 1)))

habitFieldsView fields tags descChange tagChange periodChange
    = let
        tagOption tag = option [value tag] [text tag]
    in
        [ label
            []
            [text "I want to"]
        , input 
            [ placeholder "Description", value fields.description, onInput descChange ] []
        , label
            []
            [text "Tag"]
        , input
            [ placeholder "Tag", value fields.tag, list "tag-list", onInput tagChange ] []
        , datalist
            [id "tag-list"]
            (List.map tagOption tags)
        , label
            []
            [text "Repeated every"]
        , input 
            [ placeholder "Period", value fields.period, list "period-list", onInput periodChange ] []
        , periodOptionsView fields.period "period-list"
        ]

viewEditingModal : EditModal -> List Habit -> Html Msg
viewEditingModal fields habits =
    div
        [class "modal-view"]
        (habitFieldsView
            fields
            (List.map .tag habits) 
            (\s -> UpdateModal (ChangeEditDescription s))
            (\s -> UpdateModal (ChangeEditTag s)) 
            (\s -> UpdateModal (ChangeEditPeriod s)) ++
        [div
            [class "modal-view-buttons"]
            [ button [ onClick (EditHabit fields) ] [text "Save"]
            , button [ onClick (DeleteHabit fields.id) ] [text "Delete"]
            , button [ onClick (CloseModal) ] [text "Cancel"]
            ]])

viewNewModal : NewModal -> List Habit -> Html Msg
viewNewModal fields habits =
    div
        [class "modal-view"]
        (habitFieldsView
            fields
            (List.map .tag habits)
            (\s -> UpdateModal (ChangeNewDescription s))
            (\s -> UpdateModal (ChangeNewTag s))
            (\s -> UpdateModal (ChangeNewPeriod s)) ++
        [div
            [class "modal-view-buttons"]
            [ button [ onClick (AddHabit fields) ] [text "Save"]
            , button [ onClick (CloseModal) ] [text "Cancel"]
            ]])

viewOptionsModal : OptionsModal -> Html Msg
viewOptionsModal fields =
    div
        [class "modal-view"]
        [ input 
            [ placeholder "Period", value fields.upcoming, list "upcoming-list", onInput (\s -> UpdateModal (ChangeOptionsUpcoming s)) ] []
        , periodOptionsView fields.upcoming "upcoming-list"
        , input 
            [ placeholder "Period", value fields.recent, list "recent-list", onInput (\s -> UpdateModal (ChangeOptionsRecent s)) ] []
        , periodOptionsView fields.recent "recent-list"
        , div
            [class "modal-view-buttons"]
            [ button [ onClick (SaveOptions fields) ] [text "Save"]
            , button [ onClick (CloseModal) ] [text "Cancel"]
            ]
        ]

isDueSoon: Posix -> Options -> Habit -> Bool
isDueSoon time options habit =
    posixToMillis (Habit.nextDue habit)
        < posixToMillis (addToPosix options.upcoming time)

isRecentlyDone: Posix -> Options -> Habit -> Bool
isRecentlyDone time options habit =
    (Habit.lastDone habit) 
        |> Maybe.map (\l -> posixToMillis l > posixToMillis (minusFromPosix options.recent time))
        |> Maybe.withDefault False

viewHabitFilter: Posix -> Options -> Habit -> Bool
viewHabitFilter time options habit =
    isDueSoon time options habit || isRecentlyDone time options habit

viewHabitList : Model -> Html Msg
viewHabitList {time, habits, slots, options} =
    div
        [class "slots"]
        (List.map (viewSlot time options) slots)

viewSlot : Posix -> Options -> Slot -> Html Msg
viewSlot time options slot =
    (case slot.habits of
        Both to from -> (
            div
                (class "slot" :: Animation.render slot.style)
                [viewHabit time options to, viewHabit time options from]
            )
        First habit -> (
            div
                (class "slot" :: Animation.render slot.style)
                [viewHabit time options habit, emptyDiv]
            )
        Second habit -> (
            div
                (class "slot" :: Animation.render slot.style)
                [emptyDiv, viewHabit time options habit])
            )

viewHabit : Posix -> Options -> Habit -> Html Msg
viewHabit time options habit =
    div
        [ class "habit-view" ]
        [ button 
            [ class "habit-edit"
            , onClick (OpenEditModal habit.id)
            ]
            [ text "..." ]
        , button 
            [ class "habit-button"
            , class (if isRecentlyDone time options habit then "habit-done" else "habit-todo")
            , onClick (DoHabit habit.id)
            ]
            [ span 
                [class "habit-description"]
                [text habit.description]
            , span 
                [class "habit-tag"]
                [text habit.tag] 
            ]
        ]