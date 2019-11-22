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
        , update = update
        , subscriptions = subscriptions
        }
init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        model = (logResultErr "Json Decode" (Json.Decode.decodeValue storageModelDecoder flags.model))
            |> Result.withDefault (StorageModel [] 0)
    in
        (Model flags.time model.tasks model.uid Nothing, Cmd.none)

port storeTasks : StorageModel -> Cmd msg
store : Model -> Cmd Msg -> (Model, Cmd Msg)
store model cmd =
    (model, batch [cmd, storeTasks {uid = model.uid, tasks = model.tasks}])


-- MODEL
type alias Model =
  { time : Int
  , tasks : List Task
  , uid : Int
  , modalModel : Maybe ModalModel
  }

type alias Task =
  { description : String
  , tag : String
  , id : Int
  , period : Int
  , lastDone : Maybe Int
  , nextDue : Int
  , doneCount : Int
  }

type alias StorageModel =
    { tasks : List Task
    , uid : Int
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

-- SUBSCRIPTIONS

-- Note just modal for now...
animationSubscription : Model -> Sub Msg
animationSubscription model =
    case model.modalModel of
        Just m -> (Animation.subscription Animate [ m.bgStyle, m.contentStyle ])
        Nothing -> (Sub.none)

timeSubscription : Model -> Sub Msg
timeSubscription model =
  Time.every 1000 Tick

subscriptions : Model -> Sub Msg
subscriptions model =
  Sub.batch [timeSubscription model, animationSubscription model]

-- MODAL

bgStyleClose = 
    [ Animation.to [ Animation.backgroundColor (rgba 0 0 0 0.0 ) ]
    , Animation.Messenger.send (ClearModal)
    ]

type alias ModalModel =
    { modalType : Modal
    , bgStyle : Animation.Messenger.State Msg
    , contentStyle : Animation.Messenger.State Msg
    }

type Modal
    = NewTask NewTaskModel
    | EditTask EditTaskModel
    | Options OptionsModel

type alias OptionsModel =
    { showAll : Bool
    , afterPeriod : String
    , beforePeriod : String
    }

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

-- UPDATE
type Msg
    = NoOp
    | Tick Time.Posix
    | Do Int
    | Add NewTaskModel
    | OpenModal Modal
    | CloseModal
    | ClearModal
    | Animate Animation.Msg
    | ChangeDescription NewTaskModel String
    | ChangeTag NewTaskModel String
    | ChangePeriod NewTaskModel String
    | ChangeDescriptionEdit EditTaskModel String
    | ChangeTagEdit EditTaskModel String
    | ChangePeriodEdit EditTaskModel String
    | Edit EditTaskModel
    | Delete EditTaskModel

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
        CloseModal ->
            ({model | modalModel = Maybe.map closeModal model.modalModel}, Cmd.none)
        ClearModal -> ({model | modalModel = Nothing}, Cmd.none)
        Add newTaskModel ->
            store
                { model 
                | tasks = model.tasks ++ [newTask model.time model.uid newTaskModel]
                , uid = model.uid + 1
                , modalModel = Maybe.map closeModal model.modalModel
                }
                Cmd.none
        Delete editTaskModel ->
            store
                ({ model 
                    | tasks = List.filter (\t -> t.id /= editTaskModel.id) model.tasks
                    , modalModel = Maybe.map closeModal model.modalModel
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
                    , modalModel = Maybe.map closeModal model.modalModel
                    })
                Cmd.none
        OpenModal modal ->
            let
                modalModel  = ModalModel
                    modal
                    (Animation.interrupt [ Animation.to [ Animation.backgroundColor (rgba 0 0 0 0.4 ) ] ] initalBgStyle)
                    (Animation.interrupt [ Animation.to [ Animation.top (px 0)] ] initalContentStyle)
            in
                ( { model | modalModel = Just modalModel }, Cmd.none)
        Animate animMsg ->
            case model.modalModel of
                Just m -> (
                    let
                        ( newBGStyle, cmd1 ) =
                                Animation.Messenger.update animMsg m.bgStyle
                        ( newContentStyle, cmd2 ) =
                                Animation.Messenger.update animMsg m.contentStyle
                    in
                        ( { model | modalModel = Just {m | bgStyle = newBGStyle, contentStyle = newContentStyle}}, Cmd.batch [cmd1, cmd2])
                    )
                Nothing -> (model, Cmd.none)
        ChangeDescription newTaskModel desc ->
            let
                newTaskModelUpdate m = { m | modalType = NewTask {newTaskModel | description = desc}}
            in
                ( { model | modalModel = Maybe.map newTaskModelUpdate model.modalModel}, Cmd.none )
        ChangeTag newTaskModel tag ->
            let
                newTaskModelUpdate m = { m | modalType = NewTask {newTaskModel | tag = tag}}
            in
                ( { model | modalModel = Maybe.map newTaskModelUpdate model.modalModel}, Cmd.none )
        ChangePeriod newTaskModel period ->
            let
                newTaskModelUpdate m = { m | modalType = NewTask {newTaskModel | period = period}}
            in
                ( { model | modalModel = Maybe.map newTaskModelUpdate model.modalModel}, Cmd.none )
        ChangeDescriptionEdit newTaskModel desc ->
            let
                newTaskModelUpdate m = { m | modalType = EditTask {newTaskModel | description = desc}}
            in
                ( { model | modalModel = Maybe.map newTaskModelUpdate model.modalModel}, Cmd.none )
        ChangeTagEdit newTaskModel tag ->
            let
                newTaskModelUpdate m = { m | modalType = EditTask {newTaskModel | tag = tag}}
            in
                ( { model | modalModel = Maybe.map newTaskModelUpdate model.modalModel}, Cmd.none )
        ChangePeriodEdit newTaskModel period ->
            let
                newTaskModelUpdate m = { m | modalType = EditTask {newTaskModel | period = period}}
            in
                ( { model | modalModel = Maybe.map newTaskModelUpdate model.modalModel}, Cmd.none )

-- VIEW
view : Model -> Html Msg
view model =
    let
        recentlyDone = isRecentlyDone (12*60*60*1000) model.time
        dueSoon = isDueSoon (12*60*60*1000) model.time
        isVisible task = (dueSoon task) || (recentlyDone task)
        visibleTasks = (List.sortBy .nextDue (List.filter isVisible model.tasks))
    in
        div
            [ class "wrapper" ]
                [ maybeModalView model
                , viewMenu 
                , viewTasks model.time visibleTasks
            ]

viewMenu : Html Msg
viewMenu =
    section
        [ class "menu" ]
        [
            button
                [ class "add-task", onClick (OpenModal (NewTask emptyNewTaskModel)) ]
                [ text "+" ]
        ]

viewTasks : Int -> List Task -> Html Msg
viewTasks time tasks =
    section
        [ class "main"]
        [
            Keyed.ul [ class "task-list" ] <|
            List.map (viewKeyedTask time) tasks
        ]

viewKeyedTask : Int -> Task -> ( String, Html Msg )
viewKeyedTask time task =
    ( String.fromInt task.id, lazy2 viewTask time task )

viewTask : Int -> Task -> Html Msg
viewTask time task =
    let
        recentlyDone = isRecentlyDone (12*60*60*1000) time task
    in
        li
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

maybeModalView : Model -> Html Msg
maybeModalView model =
    case model.modalModel of
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
                            _ -> (span [] [])
                    ]
                ]
            )
        Nothing -> (span [] [])

taskInputsView model descChange tagChange periodChange
    =   [ label
            []
            [text "I want to"]
        , input 
            [ placeholder "Description", value model.description, onInput descChange ] []
        , label
            []
            [text "Tag"]
        , input
            [ placeholder "Tag", value model.tag, list "tag-list", onInput tagChange ] []
        , label
            []
            [text "Repeated every"]
        , input 
            [ placeholder "Period", value model.period, list "period-list", onInput periodChange ] []
    ]

-- TODO clean up
editTaskView : EditTaskModel -> List Task -> Html Msg
editTaskView editTaskModel tasks =
    let
        tagOption tag = option [value tag] [text tag]
        findUnit = Result.withDefault 
                1
                (Parser.run Parser.int editTaskModel.period)
        periodOptions unit period =
            [ option [value (addS unit "Minute")] [text (addS unit "Minute")]
            , option [value (addS unit "Hour")] [text (addS unit "Hour")]
            , option [value (addS unit "Day")] [text (addS unit "Day")]
            , option [value (addS unit "Week")] [text (addS unit "Week")]
            , option [value (addS unit "Month")] [text (addS unit "Month")]
            ]
    in
        div [class "modal-view" ]
            (taskInputsView editTaskModel
                (ChangeDescriptionEdit editTaskModel)
                (ChangeTagEdit editTaskModel)
                (ChangePeriodEdit editTaskModel) ++
            [div
                [class "modal-view-buttons"]
                [ button [ onClick (Edit editTaskModel) ] [text "Save"]
                , button [ onClick (Delete editTaskModel) ] [text "Delete"]
                , button [ onClick (CloseModal) ] [text "Cancel"]
                ]
            , datalist
                [id "tag-list"]
                (List.map tagOption (Set.toList (Set.fromList (List.map .tag tasks))))
            , datalist
                [id "period-list"]
                ((periodOptions findUnit editTaskModel.period) ++ (periodOptions (findUnit + 1) editTaskModel.period))
            ])

newTaskView : NewTaskModel -> List Task -> Html Msg
newTaskView newTaskModel tasks =
    let
        tagOption tag = option [value tag] [text tag]
        findUnit = Result.withDefault 
                1
                (Parser.run Parser.int newTaskModel.period)   
        periodOptions unit period =
            [ option [value (addS unit "Minute")] [text (addS unit "Minute")]
            , option [value (addS unit "Hour")] [text (addS unit "Hour")]
            , option [value (addS unit "Day")] [text (addS unit "Day")]
            , option [value (addS unit "Week")] [text (addS unit "Week")]
            , option [value (addS unit "Month")] [text (addS unit "Month")]
            ]
    in
        div
            [class "modal-view" ]
            ((taskInputsView newTaskModel
                (ChangeDescription newTaskModel)
                (ChangeTag newTaskModel)
                (ChangePeriod newTaskModel)) ++
            [div
                [class "modal-view-buttons"]
                [ button [ onClick (Add newTaskModel) ] [text "Add"]
                , button [ onClick (CloseModal) ] [text "Cancel"]
                ]
            , datalist
                [id "tag-list"]
                (List.map tagOption (Set.toList (Set.fromList (List.map .tag tasks))))
            , datalist
                [id "period-list"]
                ((periodOptions findUnit newTaskModel.period) ++ (periodOptions (findUnit + 1) newTaskModel.period))
            ]) 

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