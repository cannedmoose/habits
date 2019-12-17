module Habit exposing (..)

import Dict exposing (Dict)
import Json.Decode as JD exposing (Decoder, field, int, string)
import Json.Encode as JE
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
    String


type Block
    = Blocker HabitId Bool
    | Unblocked



-- TODO CONSOLIDE BLOCK METHODS


isBlocker : HabitId -> Habit -> Bool
isBlocker habitId habit =
    case habit.block of
        Blocker otherId _ ->
            habitId == otherId

        Unblocked ->
            False


isBlockedBy : HabitId -> Habit -> Bool
isBlockedBy habitId habit =
    case habit.block of
        Blocker otherId True ->
            habitId == otherId

        _ ->
            False


isBlocked : Habit -> Bool
isBlocked habit =
    case habit.block of
        Blocker _ True ->
            True

        _ ->
            False


getBlocker : Habit -> Maybe HabitId
getBlocker habit =
    case habit.block of
        Blocker otherId _ ->
            Just otherId

        Unblocked ->
            Nothing


doUnblock : Block -> Block
doUnblock block =
    case block of
        Blocker otherId _ ->
            Blocker otherId True

        Unblocked ->
            Unblocked


unblocked : Block -> Block
unblocked block =
    case block of
        Blocker otherId True ->
            Blocker otherId False

        Blocker otherId False ->
            Blocker otherId False

        Unblocked ->
            Unblocked


blockDecoder : Decoder Block
blockDecoder =
    field "status" string
        |> JD.andThen
            (\s ->
                case s of
                    "Blocked" ->
                        JD.map2 Blocker (field "id" string) (JD.succeed True)

                    "UnblockedBy" ->
                        JD.map2 Blocker (field "id" string) (JD.succeed False)

                    _ ->
                        JD.succeed Unblocked
            )


blockJE : Block -> JE.Value
blockJE block =
    JE.object
        (case block of
            Unblocked ->
                [ ( "status", JE.string "Unblocked" ) ]

            Blocker habit True ->
                [ ( "status", JE.string "Blocked" )
                , ( "id", JE.string habit )
                ]

            Blocker habit False ->
                [ ( "status", JE.string "UnblockedBy" )
                , ( "id", JE.string habit )
                ]
        )
