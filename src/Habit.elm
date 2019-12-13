module Habit exposing (..)

import Dict exposing (Dict)
import Json.Decode as JD exposing (Decoder, field, int, string)
import Json.Encode as JE
import Period exposing (Period, addToPosix)
import Store exposing (Store)
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


newHabit : Posix -> String -> String -> HabitId -> Period -> Maybe HabitId -> Habit
newHabit time desc tag id period block =
    Habit desc
        tag
        id
        period
        Nothing
        time
        0
        (case block of
            Nothing ->
                Unblocked

            Just hid ->
                Blocker hid False
        )


getBlocker : Habit -> Maybe HabitId
getBlocker habit =
    case habit.block of
        Blocker otherId _ ->
            Just otherId

        Unblocked ->
            Nothing


isBlocker : HabitId -> Habit -> Bool
isBlocker habitId habit =
    case habit.block of
        Blocker otherId _ ->
            habitId == otherId

        Unblocked ->
            False


isBlocked : Habit -> Bool
isBlocked habit =
    case habit.block of
        Blocker _ True ->
            True

        _ ->
            False


unblock : Posix -> Habit -> Habit
unblock time habit =
    case habit.block of
        Blocker hid True ->
            { habit | block = Blocker hid False, nextDue = addToPosix habit.period time }

        _ ->
            habit


updateBlock : Maybe HabitId -> Block -> Block
updateBlock maybeBlock block =
    case ( maybeBlock, block ) of
        ( Nothing, _ ) ->
            Unblocked

        ( Just hid, Blocker _ True ) ->
            Blocker hid True

        ( Just hid, Blocker _ False ) ->
            Blocker hid False

        ( Just hid, Unblocked ) ->
            Blocker hid False


doHabit : Posix -> Habit -> Habit
doHabit time habit =
    { habit
        | lastDone = Just time
        , nextDue = addToPosix habit.period time
        , doneCount = habit.doneCount + 1
        , block =
            case habit.block of
                Blocker otherId _ ->
                    Blocker otherId True

                Unblocked ->
                    Unblocked
    }


posixDecoder : Decoder Posix
posixDecoder =
    JD.map Time.millisToPosix int


posixJE : Posix -> JE.Value
posixJE time =
    JE.int (Time.posixToMillis time)


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


decoder : Decoder Habit
decoder =
    JD.map8 Habit
        (field "description" string)
        (field "tag" string)
        (field "id" string)
        (field "period" Period.decoder)
        (JD.maybe (field "lastDone" posixDecoder))
        (field "nextDue" posixDecoder)
        (field "doneCount" int)
        (field "block" blockDecoder)


encode : Habit -> JE.Value
encode habit =
    JE.object
        ([ ( "description", JE.string habit.description )
         , ( "tag", JE.string habit.tag )
         , ( "id", JE.string habit.id )
         , ( "period", Period.encode habit.period )
         , ( "nextDue", posixJE habit.nextDue )
         , ( "doneCount", JE.int habit.doneCount )
         , ( "block", blockJE habit.block )
         ]
            ++ (case habit.lastDone of
                    Nothing ->
                        []

                    Just l ->
                        [ ( "lastDone", posixJE l ) ]
               )
        )
