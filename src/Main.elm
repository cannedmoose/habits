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
import Json.Encode as E
import Json.Decode exposing (Decoder, field, string, int)

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

port storeTasks : StorageModel -> Cmd msg

-- MODEL

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

type alias StorageModel =
    { tasks : List Task
    , uid : Int
    }
storageModelDecoder : Decoder StorageModel
storageModelDecoder =
    Json.Decode.map2 StorageModel
        (field "tasks" (Json.Decode.list taskDecoder))
        (field "uid" int)

type alias Model =
  { time : Int
  , tasks : List Task
  , uid : Int
  , newTaskModel : NewTaskModel
  }

type alias NewTaskModel =
    { description : String
    , tag : String
    , period : String
    }
emptyNewTaskModel : NewTaskModel 
emptyNewTaskModel = NewTaskModel "" "" ""

type alias Task =
  { description : String
  , tag : String
  , id : Int
  , period : Int
  , lastDone : Maybe Int
  , nextDue : Int
  , doneCount : Int
  }

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

newTask : Model -> Task
newTask model =
    { description = model.newTaskModel.description
    , tag = model.newTaskModel.tag
    , id = model.uid
    , period = getPeriodMillis model
    , lastDone = Nothing
    , nextDue = model.time
    , doneCount = 0
    }

emptyModel : Model
emptyModel =
    { time = 0
    , tasks =
        [ Task "Test Task" "Test" 1 0 Nothing (12*60*60) 1 
        , Task "Test Task 2" "Test" 2 0 Nothing (12*60*60) 1
        ]
    , uid = 3
    , newTaskModel = emptyNewTaskModel
    }

logErr : String -> Result x a -> Result x a
logErr label r =
    case r of
        Ok value -> Ok value
        Err msg -> Err (Debug.log label msg) 

init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        model = (logErr "Json Decode" (Json.Decode.decodeValue storageModelDecoder flags.model))
            |> Result.withDefault (StorageModel [] 0)
    in
        ( {emptyModel | time = flags.time, tasks = model.tasks, uid = model.uid}, Cmd.none )

-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
  Time.every 1000 Tick

-- UPDATE
type Msg
    = NoOp
    | Tick Time.Posix
    | Do Int
    | ChangeDescription String
    | ChangeTag String
    | ChangePeriod String
    | Add

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
                updateTask t =
                    if t.id == id then
                        { t | doneCount = t.doneCount + 1
                            , lastDone = Just model.time
                            , nextDue = model.time + t.period
                        }
                    else
                        t
                newTasks = List.map updateTask model.tasks
            in
            ( { model | tasks = newTasks }
            , storeTasks (StorageModel newTasks model.uid)
            )
        ChangeDescription desc ->
            let
                newTaskModel = model.newTaskModel
            in
                ( { model | newTaskModel = { newTaskModel | description = desc } }, Cmd.none )
        ChangeTag tag ->
            let
                newTaskModel = model.newTaskModel
            in
                ( { model | newTaskModel = { newTaskModel | tag = tag } }, Cmd.none )
        ChangePeriod period ->
            let
                newTaskModel = model.newTaskModel
            in
                ( { model | newTaskModel = { newTaskModel | period = period } }, Cmd.none )
        Add ->
            let
                newTaskModel = model.newTaskModel
                newTasks = model.tasks ++ [newTask model]
            in
                ( { model 
                | tasks = newTasks
                , uid = model.uid + 1
                , newTaskModel = emptyNewTaskModel
                }, storeTasks (StorageModel newTasks (model.uid + 1)))


-- VIEW

isRecentlyDone : Int -> Int -> Task -> Bool
isRecentlyDone period now task =
    Maybe.withDefault 
        False 
        (Maybe.map (\t -> now - period < t) task.lastDone)

isDueSoon : Int -> Int -> Task -> Bool
isDueSoon period now task = now + period > task.nextDue

getPeriodMillis model =
    periodToMillis (
        Result.withDefault 
        (Period 1 Day) 
        (Parser.run periodParser (
            String.toLower model.newTaskModel.period
            )
        )
    )

view : Model -> Html Msg
view model =
    let
        recentlyDone = isRecentlyDone (12*60*60) model.time
        dueSoon = isDueSoon (12*60*60) model.time
        isVisible task = (dueSoon task) || (recentlyDone task)
    in
        div
            [ class "todomvc-wrapper" ]
                [ newTaskView model 
                , viewTasks model.time (List.sortBy .nextDue (List.filter isVisible model.tasks))
                , text ((String.fromInt model.time) 
                    ++ " " 
                    ++ String.fromInt (getPeriodMillis model))
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
viewKeyedTask time todo =
    ( String.fromInt todo.id, lazy2 viewTask time todo )

viewTask : Int -> Task -> Html Msg
viewTask time todo =
    let
        recentlyDone = isRecentlyDone (12*60*60) time todo
    in
        li
            []
            [ div
                [ class "task-view" ]
                [   
                    button 
                    [ class (if recentlyDone then "task-done" else "task-todo")
                    , onClick (Do todo.id)
                    ]
                    [text (todo.description ++ " - " ++ todo.tag)]
                ]
            ]

newTaskView : Model -> Html Msg
newTaskView model =
    let
        tagOption tag = option [value tag] [text tag]
        findUnit = Result.withDefault 
                1
                (Parser.run Parser.int model.newTaskModel.period)
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
            [ class "new-view" ]
            [ input 
                [ placeholder "Description", value model.newTaskModel.description, onInput ChangeDescription ] []
            , input 
                [ placeholder "Tag", value model.newTaskModel.tag, list "tag-list", onInput ChangeTag ] []
            , input 
                [ placeholder "Period", value model.newTaskModel.period, list "period-list", onInput ChangePeriod ] []
            , button [ onClick Add ] [text "Add"]
            , datalist
                [id "tag-list"]
                (List.map tagOption (Set.toList (Set.fromList (List.map .tag model.tasks))))
            , datalist
                [id "period-list"]
                ((periodOptions findUnit model.newTaskModel.period) ++ (periodOptions (findUnit + 1) model.newTaskModel.period))
            ]
        