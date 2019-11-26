port module Main exposing (..)
import Browser
import Browser.Dom as Dom
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Html.Keyed as Keyed
import Html.Lazy exposing (lazy2)
import Set exposing (Set)
import Time
import Parser exposing (Parser, (|.), (|=), succeed, int, spaces)
import Platform.Cmd exposing (batch)
import Json.Encode as E
import Json.Decode exposing (Decoder, field, string, int)
import Animation exposing (px)
import Animation.Messenger


-- TODO figure out why we can't import this...
rgba r g b a=
    { red = r
    , green = g
    , blue = b
    , alpha = a
    }

-- Setup

type alias Flags = {time : Int, model : Json.Decode.Value}

main : Program Flags Model Msg
main =
    Browser.document
        { init = init
        , view = \model -> { title = "Tasks", body = [view model] }
        , update = (\m c -> updateWithSlots (update m c))
        , subscriptions = subscriptions
        }
init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        model = (logResultErr "Json Decode" (Json.Decode.decodeValue storageModelDecoder flags.model))
            |> Result.withDefault (StorageModel [] 0)
    in
        updateWithSlots (Model flags.time model.tasks [] model.uid Nothing newOptions, Cmd.none)

port storeTasks : StorageModel -> Cmd msg
store : Model -> Cmd Msg -> (Model, Cmd Msg)
store model cmd =
    (model, batch [cmd, storeTasks {uid = model.uid, tasks = model.tasks}])


-- MODEL
type alias Model =
  { time : Int
  , tasks : List Task
  , taskSlots : List Slot
  , uid : Int
  , modal : Maybe ModalModel
  , options : OptionsModel
  }

type alias OptionsModel =
  { recentPeriod : Int
  , upcomingPeriod : Int
  , showAll : Bool
  }

newOptions = OptionsModel (12*60*60*1000) (12*60*60*1000) False 

type alias Task =
  { description : String
  , tag : String
  , id : Int
  , period : Int
  , lastDone : Maybe Int
  , nextDue : Int
  , doneCount : Int
  }

newTask : Int -> Int -> NewTaskModel -> Task
newTask time uid model =
    { description = model.description
    , tag = model.tag
    , id = uid
    , period = getPeriodMillis model
    , lastDone = Nothing
    , nextDue = time
    , doneCount = 0
    }

type alias StorageModel =
    { tasks : List Task
    , uid : Int
    }

-- SUBSCRIPTIONS

animationSubscription : Model -> Sub Msg
animationSubscription model =
    case model.modal of
        Just m -> (Animation.subscription AnimateModal [ m.bgStyle, m.contentStyle ])
        Nothing -> (Sub.none)

slotSubscription : Model -> Sub Msg
slotSubscription model =
    Animation.subscription AnimateSlots (List.map .style model.taskSlots)

timeSubscription : Model -> Sub Msg
timeSubscription model =
  Time.every 1000 Tick

subscriptions : Model -> Sub Msg
subscriptions model =
  Sub.batch [timeSubscription model, animationSubscription model, slotSubscription model]

maybeUpdateModal : Model -> (ModalModel -> ModalModel) -> Model
maybeUpdateModal model fn = { model | modal = Maybe.map fn model.modal }

type EditField
    = EditDescription String
    | EditTag String
    | EditPeriod String

updateEditModel : EditTaskModel -> EditField -> EditTaskModel
updateEditModel model field =
    case field of
        EditDescription str -> ({model | description = str})
        EditTag str -> ({model | tag = str})
        EditPeriod str -> ({model | period = str})

maybeUpdateEditModel : EditField -> ModalModel -> ModalModel
maybeUpdateEditModel field model
    = case model.modalType of
        EditTask editModel -> ( 
                {model | modalType = EditTask (updateEditModel editModel field)}
            )
        _ -> model

type NewField
    = NewDescription String
    | NewTag String
    | NewPeriod String

updateNewModel : NewTaskModel -> NewField -> NewTaskModel
updateNewModel model field =
    case field of
        NewDescription str -> ({model | description = str})
        NewTag str -> ({model | tag = str})
        NewPeriod str -> ({model | period = str})

maybeUpdateNewModel : NewField -> ModalModel -> ModalModel
maybeUpdateNewModel field model
    = case model.modalType of
        NewTask newModel -> ( 
                {model | modalType = NewTask (updateNewModel newModel field)}
            )
        _ -> model

type OptionsField
    = OptionsRecent String
    | OptionsUpcoming String
    | OptionsShowAll Bool

updateOptionsModel : EditOptionsModel -> OptionsField -> EditOptionsModel
updateOptionsModel model field =
    case field of
        OptionsRecent str -> ({model | recentPeriod = str})
        OptionsUpcoming str -> ({model | upcomingPeriod = str})
        OptionsShowAll bool -> ({model | showAll = bool})

maybeUpdateOptionsModel : OptionsField -> ModalModel -> ModalModel
maybeUpdateOptionsModel field model
    = case model.modalType of
        Options optionsModel -> ( 
                {model | modalType = Options (updateOptionsModel optionsModel field)}
            )
        _ -> model


-- UPDATE
type Msg
    = NoOp
    | Tick Time.Posix
    | Do Int
    | Add NewTaskModel
    | OpenModal Modal
    | CloseModal
    | ClearModal
    
    | UpdateEditForm EditField
    | UpdateNewForm NewField
    | UpdateOptionsForm OptionsField

    | AnimateModal Animation.Msg
    | ChangeDescription NewTaskModel String
    | ChangeTag NewTaskModel String
    | ChangePeriod NewTaskModel String
    | ChangeDescriptionEdit EditTaskModel String
    | ChangeTagEdit EditTaskModel String
    | ChangePeriodEdit EditTaskModel String
    | Edit EditTaskModel
    | Delete EditTaskModel

    | AnimateSlots Animation.Msg
    | RmSlots

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NoOp ->
            ( model, Cmd.none ) 
        Tick newTime -> 
            ( { model | time = Time.posixToMillis(newTime) }
            , Cmd.none
            )
        Do id ->
            let
                updateTask task =
                    if task.id == id then
                        { task | doneCount = task.doneCount + 1
                            , lastDone = Just model.time
                            , nextDue = model.time + task.period
                        }
                    else
                        task
            in
            store
                { model | tasks = List.map updateTask model.tasks }
                Cmd.none
        RmSlots -> (
            ({model 
                | taskSlots =
                    List.filter 
                        (\s -> (case s.currentTask of 
                            Nothing -> (False)
                            Just b -> (True)))
                        model.taskSlots}
            )
            , Cmd.none
            )
        CloseModal ->
            ({model | modal = Maybe.map closeModal model.modal}, Cmd.none)
        ClearModal -> ({model | modal = Nothing}, Cmd.none)
        Add newTaskModel ->
            store
                { model 
                | tasks = model.tasks ++ [newTask model.time model.uid newTaskModel]
                , uid = model.uid + 1
                , modal = Maybe.map closeModal model.modal
                }
                Cmd.none
        Delete editTaskModel ->
            store
                ({ model 
                    | tasks = List.filter (\t -> t.id /= editTaskModel.id) model.tasks
                    , modal = Maybe.map closeModal model.modal
                })
                Cmd.none
        Edit editTaskModel ->
            store
                (let
                    updateTask task =
                        if task.id == editTaskModel.id then
                            {task 
                            |   description = editTaskModel.description
                            , tag = editTaskModel.tag
                            , period = getPeriodMillis editTaskModel 
                            }
                        else
                            task 
                in
                    { model
                    | tasks = List.map updateTask model.tasks
                    , modal = Maybe.map closeModal model.modal
                    })
                Cmd.none
        UpdateEditForm field ->
            (maybeUpdateModal model (maybeUpdateEditModel field), Cmd.none)
        UpdateNewForm field ->
            (maybeUpdateModal model (maybeUpdateNewModel field), Cmd.none)
        UpdateOptionsForm field ->
            (maybeUpdateModal model (maybeUpdateOptionsModel field), Cmd.none)
        OpenModal modal ->
            let
                modalModel = ModalModel
                    modal
                    (Animation.interrupt [ Animation.to [ Animation.backgroundColor (rgba 0 0 0 0.4 ) ] ] initalBgStyle)
                    (Animation.interrupt [ Animation.to [ Animation.top (px 0)] ] initalContentStyle)
            in
                ( { model | modal = Just modalModel }, Cmd.none)
        AnimateSlots animMsg ->
            let
                updateStyle s = Animation.Messenger.update animMsg s
                (slotStyles, slotCmds) = List.map .style model.taskSlots 
                    |> List.map updateStyle
                    |> List.unzip
            in
                ({model
                | taskSlots = List.map2 
                    (\slot style -> {slot | style = style})
                    model.taskSlots
                    slotStyles
                }, Cmd.batch(slotCmds))
        AnimateModal animMsg ->
            Maybe.withDefault 
                (model, Cmd.none)
                (Maybe.map
                    (\modal ->
                        let
                            updateStyle s = Animation.Messenger.update animMsg s
                            (bgStyle, cmd1) = updateStyle modal.bgStyle
                            (contentStyle, cmd2) = updateStyle modal.contentStyle 
                        in
                        ( {model
                            | modal = Just {modal | bgStyle = bgStyle, contentStyle = contentStyle}
                            }
                        , (Cmd.batch [cmd1, cmd2])
                        )
                    )
                    model.modal)
            
        ChangeDescription newTaskModel desc ->
            let
                newTaskModelUpdate m = { m | modalType = NewTask {newTaskModel | description = desc}}
            in
                ( { model | modal = Maybe.map newTaskModelUpdate model.modal}, Cmd.none )
        ChangeTag newTaskModel tag ->
            let
                newTaskModelUpdate m = { m | modalType = NewTask {newTaskModel | tag = tag}}
            in
                ( { model | modal = Maybe.map newTaskModelUpdate model.modal}, Cmd.none )
        ChangePeriod newTaskModel period ->
            let
                newTaskModelUpdate m = { m | modalType = NewTask {newTaskModel | period = period}}
            in
                ( { model | modal = Maybe.map newTaskModelUpdate model.modal}, Cmd.none )
        ChangeDescriptionEdit newTaskModel desc ->
            let
                newTaskModelUpdate m = { m | modalType = EditTask {newTaskModel | description = desc}}
            in
                ( { model | modal = Maybe.map newTaskModelUpdate model.modal}, Cmd.none )
        ChangeTagEdit newTaskModel tag ->
            let
                newTaskModelUpdate m = { m | modalType = EditTask {newTaskModel | tag = tag}}
            in
                ( { model | modal = Maybe.map newTaskModelUpdate model.modal}, Cmd.none )
        ChangePeriodEdit newTaskModel period ->
            let
                newTaskModelUpdate m = { m | modalType = EditTask {newTaskModel | period = period}}
            in
                ( { model | modal = Maybe.map newTaskModelUpdate model.modal}, Cmd.none )

closeModal m =
    { m | bgStyle = Animation.interrupt
        [ Animation.to [ Animation.backgroundColor (rgba 0 0 0 0.0) ]
        , Animation.Messenger.send (ClearModal)
        ]
        m.bgStyle
        , contentStyle = Animation.interrupt
        [ Animation.to [ Animation.top (px -300) ]
        ]
        m.contentStyle
    }

updateWithSlots : (Model, Cmd Msg) -> (Model, Cmd Msg)
updateWithSlots (model, cmd) =
    let
        recentlyDone = isRecentlyDone model.options.recentPeriod model.time
        dueSoon = isDueSoon model.options.upcomingPeriod model.time
        isVisible task = (dueSoon task) || (recentlyDone task)
        visibleTasks = (List.sortBy .nextDue (List.filter isVisible model.tasks))
    in
        ({model | taskSlots = (marrySlots model.taskSlots visibleTasks)}, cmd)

-- VIEW
view : Model -> Html Msg
view model =
    div
        [ class "wrapper" ]
            [ maybeModalView model
            , viewMenu model
            , viewTasks model
        ]

viewMenu : Model -> Html Msg
viewMenu model =
    section
        [ class "menu" ]
        [
            button
                [ class "add-task", onClick (OpenModal (NewTask emptyNewTaskModel)) ]
                [ text "+" ]
            , button
                [ class "add-task", onClick (OpenModal (Options (newEditOptionsModel model.options))) ]
                [ text "O" ]
        ]

viewTasks : Model -> Html Msg
viewTasks model =
    section
        [ class "main"]
        [
            ul [ class "task-list" ] <|
            List.map (viewSlot model) model.taskSlots
        ]

viewTask : Int -> Int -> Task -> Html Msg
viewTask time recentPeriod task =
    let
        recentlyDone = isRecentlyDone recentPeriod time task
    in
        div
            []
            [ div
                [ class "task-view" ]
                [ button 
                    [ class "task-edit"
                    , onClick (OpenModal (EditTask (EditTaskModel task.description task.tag (millisPeriodToString task.period) task.id)))
                    ]
                    [ text "..." ]
                , button 
                    [ class "task-button"
                    , class (if recentlyDone then "task-done" else "task-todo")
                    , onClick (Do task.id)
                    ]
                    [ span 
                        [class "task-description"]
                        [text task.description]
                    , span 
                        [class "task-tag"]
                        [text task.tag] 
                    ]
                ]
            ]

--SLOTS
type alias Slot = 
    { currentTask : Maybe Task
    , previousTask : Maybe Task
    , style : Animation.Messenger.State Msg
    }

-- Zip that doesnt drop items
zip : List a -> List b -> List (Maybe a, Maybe b)
zip a b =
    case a of
        aitem :: arest ->
            case b of
                bitem :: brest ->
                    ([(Just aitem, Just bitem)] ++ zip arest brest)
                _ -> [(Just aitem, Nothing)] ++ zip arest []
        _ ->
            case b of
                bitem :: brest ->
                    ([(Nothing, Just bitem)] ++ zip [] brest)
                _ -> []

slotSlideStart = (Animation.style [ Animation.left (px -800) ])
slotSlideEnd index rm = [ 
    Animation.wait (Time.millisToPosix (index * 400)),
    Animation.to [ Animation.left (px 0) ]
    ] ++ (if rm then [Animation.Messenger.send (RmSlots)] else [])

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

marry : Int -> (Maybe Slot, Maybe Task) -> (Int, Slot)
marry accum (maybeSlot, maybeTask) =
    case maybeSlot of
        Just slot -> (
            let
                sameTask = Maybe.withDefault False (Maybe.map2 (\a b -> a.id == b.id) slot.currentTask maybeTask)
                rm = Maybe.withDefault False (Maybe.map (\a -> True)maybeTask)
            in
                (accum + (if sameTask then 0 else 1), {slot
                | currentTask = maybeTask
                , previousTask = if not sameTask then slot.currentTask else slot.previousTask
                , style =
                    if sameTask then
                        slot.style
                    else (Animation.interrupt (slotSlideEnd accum rm) slotSlideStart)
                }))
        Nothing ->
            -- Slot created, should slide in
            (accum + 1, (Slot maybeTask Nothing (Animation.interrupt (slotSlideEnd accum False) slotSlideStart)))

-- This creates an updated list of slots based on the current task list...
marrySlots : List Slot -> List Task -> List Slot
marrySlots slots tasks =
    foldlMap marry 0 (zip slots tasks)

viewSlot : Model -> Slot -> Html Msg
viewSlot model slot =
    li
        ([class (case slot.currentTask of 
            Just b -> ("slot") 
            Nothing -> ("notslot"))] ++ Animation.render slot.style)
        [ Maybe.withDefault (div [] []) (Maybe.map (viewTask model.time model.options.recentPeriod) slot.currentTask)
        , Maybe.withDefault (div [] []) (Maybe.map (viewTask model.time model.options.recentPeriod) slot.previousTask)
        ]

-- MODAL VIEWS

periodOptionsView : String -> String -> Html Msg
periodOptionsView period for =
    let
        periodUnit = Result.withDefault 
                1
                (Parser.run Parser.int period)
        periodOptions unit =
            [ option [value (addS unit "Minute")] [text (addS unit "Minute")]
            , option [value (addS unit "Hour")] [text (addS unit "Hour")]
            , option [value (addS unit "Day")] [text (addS unit "Day")]
            , option [value (addS unit "Week")] [text (addS unit "Week")]
            , option [value (addS unit "Month")] [text (addS unit "Month")]
            ]  
    in
        datalist
            [id for]
            ((periodOptions periodUnit) ++ (periodOptions (periodUnit + 1)))
        

taskInputsView model tasks descChange tagChange periodChange
    = let
        tagOption tag = option [value tag] [text tag]
    in
        [ label
            []
            [text "I want to"]
        , input 
            [ placeholder "Description", value model.description, onInput descChange ] []
        , label
            []
            [text "Tag"]
        , input
            [ placeholder "Tag", value model.tag, list "tag-list", onInput tagChange ] []
        , datalist
            [id "tag-list"]
            (List.map tagOption (Set.toList (Set.fromList (List.map .tag tasks))))
        , label
            []
            [text "Repeated every"]
        , input 
            [ placeholder "Period", value model.period, list "period-list", onInput periodChange ] []
        , periodOptionsView model.period "period-list"     
        ]

editTaskView : EditTaskModel -> List Task -> Html Msg
editTaskView editTaskModel tasks
    = div [class "modal-view" ]
        (taskInputsView editTaskModel tasks
            (\s -> UpdateEditForm (EditDescription s))
            (\s -> UpdateEditForm (EditTag s))
            (\s -> UpdateEditForm (EditPeriod s)) ++
        [div
            [class "modal-view-buttons"]
            [ button [ onClick (Edit editTaskModel) ] [text "Save"]
            , button [ onClick (Delete editTaskModel) ] [text "Delete"]
            , button [ onClick (CloseModal) ] [text "Cancel"]
            ]])

newTaskView : NewTaskModel -> List Task -> Html Msg
newTaskView newTaskModel tasks
    = div
        [class "modal-view" ]
        (taskInputsView newTaskModel tasks
            (\s -> UpdateNewForm (NewDescription s))
            (\s -> UpdateNewForm (NewTag s))
            (\s -> UpdateNewForm (NewPeriod s)) ++
        [div
            [class "modal-view-buttons"]
            [ button [ onClick (Add newTaskModel) ] [text "Add"]
            , button [ onClick (CloseModal) ] [text "Cancel"]
            ]
        ]) 
        
optionsView : EditOptionsModel -> Html Msg
optionsView options =
    let
        updateRecent = (\s -> UpdateOptionsForm (OptionsRecent s))
        updateUpcoming = (\s -> UpdateOptionsForm (OptionsUpcoming s))
    in
        div
            [class "modal-view"]
            [label
                []
                [text "Show tasks completed within"]
            , input 
                [value options.recentPeriod, list "recent-list", onInput updateRecent ] []
            , periodOptionsView options.recentPeriod "recent-list"
            , label
                []
                [text "Show tasks due within"]
            , input 
                [value options.upcomingPeriod, list "upcoming-list", onInput updateUpcoming ] []
            , periodOptionsView options.upcomingPeriod "upcoming-list"
            , div
                [class "modal-view-buttons"]
                [   button [ onClick (CloseModal) ] [text "Save"]
                ]
            ]

-- MODAL

maybeModalView : Model -> Html Msg
maybeModalView model =
    case model.modal of
        Just modal -> (
            div
                ([class "modal", onClick CloseModal] ++ Animation.render modal.bgStyle)
                [ 
                    div ([(Html.Events.custom "click" (Json.Decode.succeed
                            { message = NoOp
                            , stopPropagation = True
                            , preventDefault = True
                            }
                        )), class "modal-content" ] ++ Animation.render modal.contentStyle)
                    [
                        case modal.modalType of
                            NewTask newTaskModel -> newTaskView newTaskModel model.tasks
                            EditTask editTaskModel -> editTaskView editTaskModel model.tasks
                            Options options -> optionsView options
                    ]
                ]
            )
        Nothing -> (span [] [])

type alias ModalModel =
    { modalType : Modal
    , bgStyle : Animation.Messenger.State Msg
    , contentStyle : Animation.Messenger.State Msg
    }

type Modal
    = NewTask NewTaskModel
    | EditTask EditTaskModel
    | Options EditOptionsModel

{-
ModalModel -> String -> ModalModel

modal = {modal | modalType = fn modal.modalType str}

model = {model | modal = Just fn model.modal str}
-}

type alias EditOptionsModel =
    { recentPeriod : String
    , upcomingPeriod : String
    , showAll : Bool 
    }

newEditOptionsModel options =
    EditOptionsModel 
        (millisPeriodToString options.recentPeriod)
        (millisPeriodToString options.upcomingPeriod)
        False

type alias EditTaskModel =
    { description : String
    , tag : String
    , period : String
    , id : Int
    }

type alias NewTaskModel =
    { description : String
    , tag : String
    , period : String
    }

initalBgStyle = (Animation.style [ Animation.backgroundColor (rgba 0 0 0 0.0 ) ])
initalContentStyle = (Animation.style [ Animation.top (px -800) ])
emptyNewTaskModel = NewTaskModel "" "" ""


-- HELPERS

isRecentlyDone : Int -> Int -> Task -> Bool
isRecentlyDone period now task =
    Maybe.withDefault 
        False 
        (Maybe.map (\t -> now - period < t) task.lastDone)

isDueSoon : Int -> Int -> Task -> Bool
isDueSoon period now task = now + period > task.nextDue

-- Period parsing helpers
type PeriodUnit
    = Minute
    | Hour
    | Day
    | Week
    | Month

type alias Period = 
    { amount : Int
    , unit: PeriodUnit
    }

addS : Int -> String -> String
addS unit str 
    = String.fromInt unit
    ++ " "
    ++ if (unit > 1) then str ++ "s" else str

periodUnitToMillis : PeriodUnit -> Int
periodUnitToMillis periodUnit =
    case periodUnit of
        Minute -> (60*1000)
        Hour -> (60*60*1000)
        Day -> (24*60*60*1000)
        Week -> (7*24*60*60*1000)
        Month -> (28*24*60*60*1000)

periodToMillis : Period -> Int
periodToMillis period =
    (periodUnitToMillis period.unit) * period.amount

millisPeriodToString : Int -> String
millisPeriodToString millis =
    let
        months = millis//periodUnitToMillis(Month)
        weeks = millis//periodUnitToMillis(Week)
        hours = millis//periodUnitToMillis(Hour)
        days = millis//periodUnitToMillis(Day)
        minutes = millis//periodUnitToMillis(Minute)
    in
        if months >= 1 then
            addS months "Month"
        else if weeks >= 1 then
            addS weeks "Week"
        else if days >= 1 then
            addS days "Day"
        else if hours >= 1 then
            addS hours "hour"
        else if weeks >= 1 then
            addS minutes "Minute"
        else
            "1 Minute"


periodUnitParser : Parser PeriodUnit
periodUnitParser = Parser.oneOf
    [   succeed Week |. Parser.oneOf [Parser.token "week", Parser.token "weeks"] 
        , succeed Month |. Parser.oneOf [Parser.token "month", Parser.token "months"]
        , succeed Minute |. Parser.oneOf [Parser.token "minute", Parser.token "minutes"]
        , succeed Hour |. Parser.oneOf [Parser.token "hour", Parser.token "hours"]
        , succeed Day |. Parser.oneOf [Parser.token "day", Parser.token "days"]
    ]
periodParser : Parser Period
periodParser =
    succeed Period
        |= Parser.oneOf [Parser.int ,  succeed 1]
        |. spaces
        |= periodUnitParser

getPeriodMillis model =
    periodToMillis (
        Result.withDefault 
        (Period 1 Day) 
        (Parser.run periodParser (
            String.toLower model.period
            )
        )
    )


-- Debug logs and error message from a result, returning original result. 
logResultErr : String -> Result x a -> Result x a
logResultErr label r =
    case r of
        Ok value -> Ok value
        Err msg -> Err (Debug.log label msg) 

-- JSON Decoding

storageModelDecoder : Decoder StorageModel
storageModelDecoder =
    Json.Decode.map2 StorageModel
        (field "tasks" (Json.Decode.list taskDecoder))
        (field "uid" int)

taskDecoder : Decoder Task
taskDecoder =
    Json.Decode.map7 Task
        (field "description" string)
        (field "tag" string)
        (field "id" int)
        (field "period" int)
        (Json.Decode.maybe (field "lastDone" int))
        (field "nextDue" int)
        (field "doneCount" int)