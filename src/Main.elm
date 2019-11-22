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
  , newTaskModel : Maybe NewTaskModel
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

type alias NewTaskModel =
    { description : String
    , tag : String
    , period : String
    , style : Animation.Messenger.State Msg
    }

emptyNewTaskModel = NewTaskModel "" "" "" (Animation.style [ Animation.opacity 0 ])

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

animationSubscription : Model -> Sub Msg
animationSubscription model =
    case model.newTaskModel of
        Just m -> (Animation.subscription Animate [ m.style ])
        Nothing -> (Sub.none)

timeSubscription : Model -> Sub Msg
timeSubscription model =
  Time.every 1000 Tick

subscriptions : Model -> Sub Msg
subscriptions model =
  Sub.batch [timeSubscription model, animationSubscription model]

-- UPDATE
type Msg
    = NoOp
    | Tick Time.Posix
    | Do Int
    | Add
    | ShowAddTask
    | ChangeDescription String
    | ChangeTag String
    | ChangePeriod String
    | Animate Animation.Msg
    | ClearNewTask

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
        Add ->
            let
                newTaskModel = model.newTaskModel
            in
                case newTaskModel of
                    Just m -> 
                        ( store
                            { model 
                            | tasks = model.tasks ++ [newTask model.time model.uid m]
                            , uid = model.uid + 1
                            , newTaskModel = 
                                Just { m 
                                | style = Animation.interrupt
                                    [ Animation.to 
                                        [ Animation.opacity 0.0 ]
                                        , Animation.Messenger.send (ClearNewTask)
                                    ]
                                    m.style
                                }
                            }
                            Cmd.none
                        )
                    Nothing -> (model, Cmd.none)
        ShowAddTask ->
            let
                emptyModel = emptyNewTaskModel
                emptyModel2 = { emptyModel | style = Animation.interrupt
                    [ Animation.to 
                        [ Animation.opacity 1.0 ]
                    ]
                    emptyModel.style }
            in
                ( { model | newTaskModel = Just emptyModel2 }
                , Cmd.none)
        Animate animMsg -> 
            ( { model | 
                newTaskModel = (Maybe.map 
                    (\m -> {m | style =  Animation.update animMsg m.style}) 
                    model.newTaskModel) }
            , Cmd.none)
        ClearNewTask -> ({model | newTaskModel = Nothing}, Cmd.none)
        ChangeDescription desc ->
            let
                newTaskModel = model.newTaskModel
                newTaskModelUpdate m = { m | description = desc}
            in
                ( { model | newTaskModel = Maybe.map newTaskModelUpdate newTaskModel}, Cmd.none )
        ChangeTag tag ->
            let
                newTaskModel = model.newTaskModel
                newTaskModelUpdate m = { m | tag = tag}
            in
                ( { model | newTaskModel = Maybe.map newTaskModelUpdate newTaskModel}, Cmd.none )
        ChangePeriod period ->
            let
                newTaskModel = model.newTaskModel
                newTaskModelUpdate m = { m | period = period}
            in
                ( { model | newTaskModel = Maybe.map newTaskModelUpdate newTaskModel}, Cmd.none )

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
                [ viewMenu
                , maybeNewTaskView model.newTaskModel model.tasks 
                , viewTasks model.time visibleTasks
            ]

viewMenu : Html Msg
viewMenu =
    section
        [ class "menu" ]
        [
            button
                [ class "add-task", onClick (ShowAddTask) ]
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
                    , onClick (Do task.id)
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

-- TODO clean up
maybeNewTaskView : Maybe NewTaskModel -> List Task -> Html Msg
maybeNewTaskView model =
    case model of
        Just m -> (newTaskView m)
        Nothing -> (\_ -> (span [] []))
newTaskView : NewTaskModel -> List Task -> Html Msg
newTaskView newTaskModel tasks =
    let
        tagOption tag = option [value tag] [text tag]
        findUnit = Result.withDefault 
                1
                (Parser.run Parser.int newTaskModel.period)
        addS unit str = if (unit > 1) then String.fromInt unit ++ " " ++ str ++ "s" else str   
        periodOptions unit period =
            [ option [value (addS unit "Minute")] [text (addS unit "Minute")]
            , option [value (addS unit "Hour")] [text (addS unit "Hour")]
            , option [value (addS unit "Day")] [text (addS unit "Day")]
            , option [value (addS unit "Week")] [text (addS unit "Week")]
            , option [value (addS unit "Month")] [text (addS unit "Month")]
            ]
    in
        div
            ([ class "new-view" ] ++ Animation.render newTaskModel.style)
            [ input 
                [ placeholder "Description", value newTaskModel.description, onInput ChangeDescription ] []
            , input 
                [ placeholder "Tag", value newTaskModel.tag, list "tag-list", onInput ChangeTag ] []
            , input 
                [ placeholder "Period", value newTaskModel.period, list "period-list", onInput ChangePeriod ] []
            , button [ onClick Add ] [text "Add"]
            , datalist
                [id "tag-list"]
                (List.map tagOption (Set.toList (Set.fromList (List.map .tag tasks))))
            , datalist
                [id "period-list"]
                ((periodOptions findUnit newTaskModel.period) ++ (periodOptions (findUnit + 1) newTaskModel.period))
            ]

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
periodToMillis : Period -> Int
periodToMillis period =
    case (period.unit) of
        Minute -> (60*1000*period.amount)
        Hour -> (60*60*1000*period.amount)
        Day -> (24*60*60*1000*period.amount)
        Week -> (7*24*60*60*1000*period.amount)
        Month -> (28*24*60*60*1000*period.amount)

periodUnitParser : Parser PeriodUnit
periodUnitParser = Parser.oneOf
    [   succeed Week |. Parser.token "week"
        , succeed Month |. Parser.token "month"
        , succeed Minute |. Parser.token "minute"
        , succeed Hour |. Parser.token "hour"
        , succeed Day |. Parser.token "day"
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