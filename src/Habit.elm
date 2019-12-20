module Habit exposing (Block(..), Habit, HabitId, blockDecoder, blockJE, blockerId, doBlock, doUnblock, isBlocked, isBlocker)

import Json.Decode as JD exposing (Decoder, field, string)
import Json.Encode as JE
import Period exposing (Period)
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


isBlocker : HabitId -> Habit -> Bool
isBlocker habitId habit =
    blockerId habit
        |> Maybe.map ((==) habitId)
        |> Maybe.withDefault False


isBlocked : Habit -> Bool
isBlocked habit =
    case habit.block of
        Blocker _ True ->
            True

        _ ->
            False


doUnblock : Block -> Block
doUnblock block =
    case block of
        Blocker otherId _ ->
            Blocker otherId False

        Unblocked ->
            Unblocked


doBlock : Block -> Block
doBlock block =
    case block of
        Blocker otherId _ ->
            Blocker otherId True

        Unblocked ->
            Unblocked


blockerId : Habit -> Maybe HabitId
blockerId habit =
    case habit.block of
        Blocker otherId _ ->
            Just otherId

        Unblocked ->
            Nothing


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
