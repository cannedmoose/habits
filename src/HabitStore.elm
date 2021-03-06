module HabitStore exposing (..)

import Dict exposing (Dict)
import Habit exposing (Habit, HabitId)
import Json.Decode as JD
import Json.Encode as JE
import Period exposing (Period)
import Time exposing (Posix)



{-
   HabitDeltas are low level (eg they don't know what "doing" a habit means)
     its just an update of the habit being done and it's dependendents

   Grouping are basically comments to say "this set of operations is logically this thing"

   The Deltas can be encoded to a Json Value
   The Deltas can be decoded to a Store of habits


   its up to implemention to realize if somethig is an invalid state
-}


type HabitFieldChange
    = DescriptionChange String
    | TagChange String
    | PeriodChange Period
    | LastDoneChange Posix
    | NextDueChange Posix
    | DoneCountChange Int
    | IsBlockedChange Bool
    | BlockerChange (Maybe HabitId)


type HabitDelta
    = AddHabit Habit.HabitId
    | DeleteHabit Habit.HabitId
    | ChangeHabit Habit.HabitId HabitFieldChange
    | Group Posix String



-- Delta generators


doHabitDeltas : Dict HabitId Habit -> Posix -> Habit -> List HabitDelta
doHabitDeltas store time habit =
    let
        blockedHabits =
            Dict.filter (\_ h -> (h.blocker == Just habit.id) && h.isBlocked) store
                |> Dict.toList
    in
    [ Group time ("do " ++ habit.id)

    -- Update
    , ChangeHabit habit.id (LastDoneChange time)
    , ChangeHabit habit.id (NextDueChange (Period.addToPosix habit.period time))
    , ChangeHabit habit.id (DoneCountChange (habit.doneCount + 1))
    ]
        ++ (if habit.blocker /= Nothing then
                [ ChangeHabit habit.id (IsBlockedChange True)
                ]

            else
                []
           )
        -- Update Blocked habits
        ++ List.concatMap
            (\( hid, h ) ->
                [ ChangeHabit hid (IsBlockedChange False)
                , ChangeHabit hid (NextDueChange (Period.addToPosix h.period time))
                ]
            )
            blockedHabits


undoHabitDeltas : Dict HabitId Habit -> Posix -> Habit -> List HabitDelta
undoHabitDeltas store time habit =
    let
        blockedHabits =
            Dict.filter (\_ h -> (h.blocker == Just habit.id) && not h.isBlocked) store
                |> Dict.keys
    in
    [ Group time ("do " ++ habit.id)

    -- Update
    , ChangeHabit habit.id (LastDoneChange (Period.minusFromPosix habit.period time))
    , ChangeHabit habit.id (NextDueChange time)
    , ChangeHabit habit.id (DoneCountChange (habit.doneCount - 1))
    ]
        ++ (if habit.isBlocked then
                [ ChangeHabit habit.id (IsBlockedChange False)
                ]

            else
                []
           )
        -- Update Blocked habits
        ++ List.concatMap
            (\hid ->
                [ ChangeHabit hid (IsBlockedChange True) ]
            )
            blockedHabits


deleteHabitDeltas : Dict HabitId Habit -> Posix -> Habit.HabitId -> List HabitDelta
deleteHabitDeltas store time habitId =
    let
        blockedHabits =
            Dict.filter (\_ h -> h.blocker == Just habitId) store
                |> Dict.keys
    in
    [ Group time ("delete " ++ habitId)

    -- Delete Habit
    , DeleteHabit habitId

    -- Update Blocked habits
    ]
        ++ List.map
            (\hid -> ChangeHabit hid (BlockerChange Nothing))
            blockedHabits


editHabitDeltas : Dict HabitId Habit -> Posix -> Habit.HabitId -> List HabitFieldChange -> List HabitDelta
editHabitDeltas _ time habitId changes =
    let
        changeDeltas =
            List.map (ChangeHabit habitId) changes
    in
    Group time ("edit " ++ habitId)
        :: changeDeltas


addHabitDeltas : Dict HabitId Habit -> Posix -> Habit.HabitId -> List HabitFieldChange -> List HabitDelta
addHabitDeltas _ time habitId changes =
    let
        changeDeltas =
            List.map (ChangeHabit habitId) changes
    in
    List.concat
        [ [ Group time ("add " ++ habitId)
          , AddHabit habitId
          , ChangeHabit habitId (NextDueChange time)
          ]
        , changeDeltas
        ]


buildFieldChanges : HabitFieldChange -> List HabitFieldChange -> List HabitFieldChange
buildFieldChanges delta deltas =
    {- Add a field change to a list replacing existing field chang if one exists -}
    case ( deltas, delta ) of
        ( (DescriptionChange _) :: xs, DescriptionChange _ ) ->
            delta :: xs

        ( (TagChange _) :: xs, TagChange _ ) ->
            delta :: xs

        ( (LastDoneChange _) :: xs, LastDoneChange _ ) ->
            delta :: xs

        ( (NextDueChange _) :: xs, NextDueChange _ ) ->
            delta :: xs

        ( (DoneCountChange _) :: xs, DoneCountChange _ ) ->
            delta :: xs

        ( (BlockerChange _) :: xs, BlockerChange _ ) ->
            delta :: xs

        ( (IsBlockedChange _) :: xs, IsBlockedChange _ ) ->
            delta :: xs

        ( [], _ ) ->
            [ delta ]

        ( d :: xs, _ ) ->
            d :: buildFieldChanges delta xs


deltasFromHabit : HabitId -> Habit -> List HabitDelta
deltasFromHabit id habit =
    [ AddHabit id
    , ChangeHabit id (DescriptionChange habit.description)
    , ChangeHabit id (TagChange habit.tag)
    , ChangeHabit id (NextDueChange habit.nextDue)
    , ChangeHabit id (DoneCountChange habit.doneCount)
    , ChangeHabit id (BlockerChange habit.blocker)
    , ChangeHabit id (IsBlockedChange habit.isBlocked)
    , ChangeHabit id (PeriodChange habit.period)
    ]
        ++ (case habit.lastDone of
                Just c ->
                    [ ChangeHabit id (LastDoneChange c) ]

                Nothing ->
                    []
           )


deltasFromDict : Posix -> Dict HabitId Habit -> List HabitDelta
deltasFromDict time dict =
    Group time "bot"
        :: (Dict.map
                deltasFromHabit
                dict
                |> Dict.values
                |> List.concat
           )



-- Delta Applicatoin


applyDeltas : Dict HabitId Habit -> List HabitDelta -> Dict HabitId Habit
applyDeltas store deltas =
    List.foldl applyDelta store deltas


applyDelta : HabitDelta -> Dict HabitId Habit -> Dict HabitId Habit
applyDelta delta store =
    case delta of
        AddHabit id ->
            Dict.insert id (emptyHabit id) store

        DeleteHabit id ->
            Dict.remove id store

        ChangeHabit id change ->
            Dict.update id (applyFieldChange change) store

        Group _ _ ->
            store


emptyHabit : HabitId -> Habit
emptyHabit id =
    { description = ""
    , tag = ""
    , id = id
    , period = Period.fromString 1 "Day"
    , lastDone = Nothing
    , nextDue = Time.millisToPosix 0
    , doneCount = 0
    , blocker = Nothing
    , isBlocked = False
    }


applyFieldChange : HabitFieldChange -> Maybe Habit -> Maybe Habit
applyFieldChange change maybeHabit =
    case ( maybeHabit, change ) of
        ( Just habit, DescriptionChange c ) ->
            Just { habit | description = c }

        ( Just habit, TagChange c ) ->
            Just { habit | tag = c }

        ( Just habit, LastDoneChange c ) ->
            Just { habit | lastDone = Just c }

        ( Just habit, NextDueChange c ) ->
            Just { habit | nextDue = c }

        ( Just habit, DoneCountChange c ) ->
            Just { habit | doneCount = c }

        ( Just habit, BlockerChange c ) ->
            Just { habit | blocker = c }

        ( Just habit, IsBlockedChange c ) ->
            Just { habit | isBlocked = c }

        ( Just habit, PeriodChange c ) ->
            Just { habit | period = c }

        ( Nothing, _ ) ->
            Nothing



-- Encode/Decode


decoder : JD.Decoder HabitDelta
decoder =
    JD.field "type" JD.int
        |> JD.andThen
            (\deltaType ->
                case deltaType of
                    0 ->
                        addHabitDecoder

                    1 ->
                        deleteHabitDecoder

                    2 ->
                        changeHabitDecoder

                    3 ->
                        groupDecoder

                    x ->
                        JD.fail ("Unknown delta type " ++ String.fromInt x)
            )


addHabitDecoder : JD.Decoder HabitDelta
addHabitDecoder =
    JD.map AddHabit (JD.field "id" JD.string)


deleteHabitDecoder : JD.Decoder HabitDelta
deleteHabitDecoder =
    JD.map DeleteHabit (JD.field "id" JD.string)


changeHabitDecoder : JD.Decoder HabitDelta
changeHabitDecoder =
    JD.map2 ChangeHabit (JD.field "id" JD.string) (JD.field "change" fieldChangeDecoder)


fieldChangeDecoder : JD.Decoder HabitFieldChange
fieldChangeDecoder =
    JD.field "type" JD.int
        |> JD.andThen
            (\field ->
                case field of
                    0 ->
                        JD.map DescriptionChange (JD.field "val" JD.string)

                    1 ->
                        JD.map TagChange (JD.field "val" JD.string)

                    2 ->
                        JD.map LastDoneChange (JD.field "val" posixDecoder)

                    3 ->
                        JD.map NextDueChange (JD.field "val" posixDecoder)

                    4 ->
                        JD.map DoneCountChange (JD.field "val" JD.int)

                    5 ->
                        JD.map PeriodChange (JD.field "val" Period.decoder)

                    6 ->
                        JD.map BlockerChange (JD.field "val" (JD.nullable JD.string))

                    7 ->
                        JD.map IsBlockedChange (JD.field "val" JD.bool)

                    x ->
                        JD.fail ("Unknown field type " ++ String.fromInt x)
            )


posixDecoder : JD.Decoder Posix
posixDecoder =
    JD.map Time.millisToPosix JD.int


groupDecoder : JD.Decoder HabitDelta
groupDecoder =
    JD.map2 Group (JD.field "time" posixDecoder) (JD.field "desc" JD.string)


encode : HabitDelta -> JE.Value
encode delta =
    case delta of
        AddHabit id ->
            JE.object [ ( "type", JE.int 0 ), ( "id", JE.string id ) ]

        DeleteHabit id ->
            JE.object [ ( "type", JE.int 1 ), ( "id", JE.string id ) ]

        ChangeHabit id change ->
            JE.object [ ( "type", JE.int 2 ), ( "id", JE.string id ), ( "change", fieldChangeEncode change ) ]

        Group time desc ->
            JE.object [ ( "type", JE.int 3 ), ( "time", posixEncode time ), ( "desc", JE.string desc ) ]


fieldChangeEncode : HabitFieldChange -> JE.Value
fieldChangeEncode change =
    case change of
        DescriptionChange c ->
            JE.object [ ( "type", JE.int 0 ), ( "val", JE.string c ) ]

        TagChange c ->
            JE.object [ ( "type", JE.int 1 ), ( "val", JE.string c ) ]

        LastDoneChange c ->
            JE.object [ ( "type", JE.int 2 ), ( "val", posixEncode c ) ]

        NextDueChange c ->
            JE.object [ ( "type", JE.int 3 ), ( "val", posixEncode c ) ]

        DoneCountChange c ->
            JE.object [ ( "type", JE.int 4 ), ( "val", JE.int c ) ]

        PeriodChange c ->
            JE.object [ ( "type", JE.int 5 ), ( "val", Period.encode c ) ]

        BlockerChange c ->
            JE.object
                [ ( "type", JE.int 6 )
                , ( "val"
                  , case c of
                        Nothing ->
                            JE.null

                        Just id ->
                            JE.string id
                  )
                ]

        IsBlockedChange c ->
            JE.object [ ( "type", JE.int 7 ), ( "val", JE.bool c ) ]


posixEncode : Posix -> JE.Value
posixEncode time =
    JE.int (Time.posixToMillis time)
