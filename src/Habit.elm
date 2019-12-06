module Habit exposing (..)

import Dict exposing (..)
import Json.Decode exposing (Decoder, field, int, string)
import Json.Encode as Encode
import Period exposing (Period, addToPosix)
import Time exposing (Posix)


type alias Habit =
    { description : String
    , tag : String
    , id : HabitId
    , period : Period
    , lastDone : Maybe Posix
    , nextDue : Posix
    , doneCount : Int
    , block : Block
    }


type alias HabitId =
    Int


type Block
    = BlockedBy HabitId
    | UnblockedBy HabitId
    | Unblocked


newHabit : Posix -> String -> String -> HabitId -> Period -> Maybe HabitId -> Habit
newHabit time desc t i p block =
    Habit desc
        t
        i
        p
        Nothing
        time
        0
        (case block of
            Nothing ->
                Unblocked

            Just hid ->
                UnblockedBy hid
        )


description : Habit -> String
description habit =
    habit.description


setDescription : String -> Habit -> Habit
setDescription desc habit =
    { habit | description = desc }


tag : Habit -> String
tag habit =
    habit.tag


setTag : String -> Habit -> Habit
setTag t habit =
    { habit | tag = t }


period : Habit -> Period
period habit =
    habit.period


setPeriod : Period -> Habit -> Habit
setPeriod p habit =
    { habit | period = p }


id : Habit -> HabitId
id habit =
    habit.id


nextDue : Habit -> Posix
nextDue habit =
    habit.nextDue


lastDone : Habit -> Maybe Posix
lastDone habit =
    habit.lastDone


doHabit : Posix -> Habit -> Habit
doHabit time habit =
    { habit
        | lastDone = Just time
        , nextDue = addToPosix habit.period time
        , doneCount = habit.doneCount + 1
        , block =
            case habit.block of
                UnblockedBy otherId ->
                    BlockedBy otherId

                BlockedBy otherId ->
                    BlockedBy otherId

                Unblocked ->
                    Unblocked
    }


do : Posix -> Dict HabitId Habit -> HabitId -> Dict HabitId Habit
do time habits habitId =
    -- TODO update blocked habits
    Dict.update
        habitId
        (Maybe.map (doHabit time))
        habits


posixDecoder : Decoder Posix
posixDecoder =
    Json.Decode.map Time.millisToPosix int


posixEncode : Posix -> Encode.Value
posixEncode time =
    Encode.int (Time.posixToMillis time)



-- TODO Fix this shiz


blockDecoder : Decoder Block
blockDecoder =
    field "status" string
        |> Json.Decode.andThen
            (\s ->
                case s of
                    "Blocked" ->
                        Json.Decode.map BlockedBy (field "id" int)

                    "UnblockedBy" ->
                        Json.Decode.map UnblockedBy (field "id" int)

                    _ ->
                        Json.Decode.succeed Unblocked
            )


blockEncode : Block -> Encode.Value
blockEncode block =
    Encode.object
        (case block of
            Unblocked ->
                [ ( "status", Encode.string "Unblocked" ) ]

            BlockedBy habit ->
                [ ( "status", Encode.string "Blocked" )
                , ( "id", Encode.int habit )
                ]

            UnblockedBy habit ->
                [ ( "status", Encode.string "UnblockedBy" )
                , ( "id", Encode.int habit )
                ]
        )


decoder : Decoder Habit
decoder =
    Json.Decode.map8 Habit
        (field "description" string)
        (field "tag" string)
        (field "id" int)
        (field "period" Period.decoder)
        (Json.Decode.maybe (field "lastDone" posixDecoder))
        (field "nextDue" posixDecoder)
        (field "doneCount" int)
        (field "block" blockDecoder)


encode : Habit -> Encode.Value
encode habit =
    Encode.object
        ([ ( "description", Encode.string habit.description )
         , ( "tag", Encode.string habit.tag )
         , ( "id", Encode.int habit.id )
         , ( "period", Period.encode habit.period )
         , ( "nextDue", posixEncode habit.nextDue )
         , ( "doneCount", Encode.int habit.doneCount )
         , ( "block", blockEncode habit.block )
         ]
            ++ (case habit.lastDone of
                    Nothing ->
                        []

                    Just l ->
                        [ ( "lastDone", posixEncode l ) ]
               )
        )
