module Habit exposing (Habit, HabitId, isDue)

import Period exposing (Period)
import Time exposing (Posix, posixToMillis)


type alias Habit =
    { description : String
    , tag : String
    , id : HabitId
    , period : Period
    , lastDone : Maybe Posix
    , nextDue : Posix
    , doneCount : Int
    , isBlocked : Bool
    , blocker : Maybe HabitId
    }


type alias HabitId =
    String


isDue : Posix -> Habit -> Bool
isDue time habit =
    posixToMillis habit.nextDue
        < posixToMillis time
