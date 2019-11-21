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
        (Model flags.time model.tasks model.uid emptyNewTaskModel, Cmd.none)

port storeTasks : StorageModel -> Cmd msg
store : Model -> Cmd Msg -> (Model, Cmd Msg)
store model cmd =
    (model, batch [cmd, storeTasks {uid = model.uid, tasks = model.tasks}])


-- MODEL
type alias Model =
  { time : Int
  , tasks : List Task
  , uid : Int
  , newTaskModel : NewTaskModel
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
    }

emptyNewTaskModel = NewTaskModel "" "" ""

type alias StorageModel =
    { tasks : List Task
    , uid : Int
    }

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
                newTasks = model.tasks ++ [newTask model]
            in
                store
                    { model 
                    | tasks = model.tasks ++ [newTask model]
                    , uid = model.uid + 1
                    , newTaskModel = emptyNewTaskModel
                    }
                    Cmd.none
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

-- VIEW
view : Model -> Html Msg
view model =
    let
        recentlyDone = isRecentlyDone (12*60*60) model.time
        dueSoon = isDueSoon (12*60*60) model.time
        isVisible task = (dueSoon task) || (recentlyDone task)
        visibleTasks = (List.sortBy .nextDue (List.filter isVisible model.tasks))
    in
        div
            [ class "wrapper" ]
                [ newTaskView model 
                , viewTasks model.time visibleTasks
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
        recentlyDone = isRecentlyDone (12*60*60) time task
    in
        li
            []
            [ div
                [ class "task-view" ]
                [   
                    button 
                    [ class (if recentlyDone then "task-done" else "task-todo")
                    , onClick (Do task.id)
                    ]
                    [text (task.description ++ " - " ++ task.tag)]
                ]
            ]

-- TODO clean up
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
            String.toLower model.newTaskModel.period
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