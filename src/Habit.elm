module Habit exposing (Habit, description, tag, period, id, nextDue, lastDone, setDescription, setTag, setPeriod, do, newHabit, Id(..))
import Period exposing (Period, addToPosix)
import Time exposing (Posix)
import Json.Decode exposing (Decoder, field, string, int)
import Json.Encode as Encode

type alias Habit =
  { description : String
  , tag : String
  , id : Id
  , period : Period
  , lastDone : Maybe Posix 
  , nextDue : Posix
  , doneCount : Int
  }

type Id = HabitId Int

newHabit: Posix -> String -> String -> Id -> Period -> Habit
newHabit time desc t i p =
  Habit desc t i p Nothing time 0

description: Habit -> String
description habit = habit.description

setDescription: String -> Habit -> Habit
setDescription desc habit = {habit | description = desc}

tag: Habit -> String
tag habit = habit.tag

setTag: String -> Habit -> Habit
setTag t habit = {habit | tag = t}

period: Habit -> Period
period habit = habit.period

setPeriod: Period -> Habit -> Habit
setPeriod p habit = {habit | period = p}

id: Habit -> Id
id habit = habit.id

nextDue: Habit -> Posix
nextDue habit = habit.nextDue

lastDone: Habit -> Maybe Posix
lastDone habit = habit.lastDone

do: Posix -> Habit -> Habit
do time habit =
  { habit 
  | lastDone = Just time
  , nextDue = addToPosix habit.period time
  , doneCount = habit.doneCount + 1
  } 

posixDecoder: Decoder Posix
posixDecoder =
  Json.Decode.map (Time.millisToPosix) int 

posixEncode: Posix -> Encode.Value
posixEncode time =
  Encode.int (Time.posixToMillis time) 


decoder : Decoder Habit
decoder =
  Json.Decode.map7 Habit
      (field "description" string)
      (field "tag" string)
      ((field "id" int) |> Json.Decode.map HabitId)
      (field "period" Period.decoder)
      (Json.Decode.maybe (field "lastDone" posixDecoder))
      (field "nextDue" posixDecoder)
      (field "doneCount" int)

idToInt (HabitId i) = i

encode : Habit -> Encode.Value
encode habit =
  Encode.object ([
    ("description", Encode.string habit.description)
    , ("tag", Encode.string habit.tag)
    , ("id", Encode.int (idToInt habit.id))
    , ("period", Period.encode habit.period) 
    , ("nextDue", posixEncode habit.nextDue)
    , ("doneCount", Encode.int habit.doneCount)
  ] ++ (case habit.lastDone of
    Nothing -> []
    Just l -> [("lastDone", posixEncode l)]
  ))