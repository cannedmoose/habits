module Habit exposing (Block(..), Habit, Id(..), decoder, description, do, encode, id, idToInt, lastDone, newHabit, nextDue, period, setDescription, setPeriod, setTag, tag)

import Json.Decode exposing (Decoder, field, int, string)
import Json.Encode as Encode
import Period exposing (Period, addToPosix)
import Time exposing (Posix)


type alias Habit =
    { description : String
    , tag : String
    , id : Id
    , period : Period
    , lastDone : Maybe Posix
    , nextDue : Posix
    , doneCount : Int
    , block : Block
    }


type Id
    = HabitId Int


type Block
    = BlockedBy Id
    | UnblockedBy Id
    | Unblocked


newHabit : Posix -> String -> String -> Id -> Period -> Maybe Id -> Habit
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


id : Habit -> Id
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


do : Posix -> List Habit -> Id -> List Habit
do time habits habitId =
    List.map
        (\h ->
            if h.id == habitId then
                doHabit time h

            else
                case h.block of
                    Unblocked ->
                        h

                    UnblockedBy _ ->
                        h

                    BlockedBy otherId ->
                        if otherId == habitId then
                            { h | block = UnblockedBy otherId, nextDue = addToPosix h.period time }

                        else
                            h
        )
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
                        Json.Decode.map BlockedBy (field "id" int |> Json.Decode.map HabitId)

                    "UnblockedBy" ->
                        Json.Decode.map UnblockedBy (field "id" int |> Json.Decode.map HabitId)

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
                , ( "id", Encode.int (idToInt habit) )
                ]

            UnblockedBy habit ->
                [ ( "status", Encode.string "UnblockedBy" )
                , ( "id", Encode.int (idToInt habit) )
                ]
        )


decoder : Decoder Habit
decoder =
    Json.Decode.map8 Habit
        (field "description" string)
        (field "tag" string)
        (field "id" int |> Json.Decode.map HabitId)
        (field "period" Period.decoder)
        (Json.Decode.maybe (field "lastDone" posixDecoder))
        (field "nextDue" posixDecoder)
        (field "doneCount" int)
        (field "block" blockDecoder)


idToInt (HabitId i) =
    i


encode : Habit -> Encode.Value
encode habit =
    Encode.object
        ([ ( "description", Encode.string habit.description )
         , ( "tag", Encode.string habit.tag )
         , ( "id", Encode.int (idToInt habit.id) )
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
