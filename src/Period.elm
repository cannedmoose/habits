module Period exposing (..)

import Json.Decode as JD exposing (Decoder)
import Json.Encode as Encode
import Parser exposing ((|.), (|=), Parser, int, spaces, succeed)
import Time exposing (Posix)


type Period
    = Minutes Int
    | Hours Int
    | Days Int
    | Weeks Int
    | Months Int


addToPosix : Period -> Posix -> Posix
addToPosix period time =
    Time.millisToPosix (Time.posixToMillis time + toMillis period)


minusFromPosix : Period -> Posix -> Posix
minusFromPosix period time =
    Time.millisToPosix (Time.posixToMillis time - toMillis period)


toMillis : Period -> Int
toMillis period =
    case period of
        Minutes i ->
            i * 60 * 1000

        Hours i ->
            i * 60 * 60 * 1000

        Days i ->
            i * 24 * 60 * 60 * 1000

        Weeks i ->
            i * 7 * 24 * 60 * 60 * 1000

        Months i ->
            i * 28 * 24 * 60 * 60 * 1000


addS : Int -> String -> String
addS unit str =
    String.fromInt unit
        ++ " "
        ++ (if unit > 1 then
                str ++ "s"

            else
                str
           )


toString : Period -> String
toString period =
    case period of
        Minutes i ->
            addS i "Minute"

        Hours i ->
            addS i "Hour"

        Days i ->
            addS i "Day"

        Weeks i ->
            addS i "Week"

        Months i ->
            addS i "Month"


fromString : Int -> String -> Period
fromString amount string =
    case string of
        "Minutes" ->
            Minutes amount

        "Hours" ->
            Hours amount

        "Days" ->
            Days amount

        "Weeks" ->
            Weeks amount

        "Months" ->
            Months amount

        _ ->
            Days 1


decoder : Decoder Period
decoder =
    JD.map parse JD.string


encode : Period -> Encode.Value
encode period =
    Encode.string (toString period)


parse : String -> Period
parse string =
    String.toLower string
        |> Parser.run periodParser
        |> Result.withDefault (Days 1)


periodUnitParser : Int -> Parser Period
periodUnitParser amount =
    Parser.oneOf
        [ succeed (Weeks amount) |. Parser.oneOf [ Parser.token "week", Parser.token "weeks" ]
        , succeed (Months amount) |. Parser.oneOf [ Parser.token "month", Parser.token "months" ]
        , succeed (Minutes amount) |. Parser.oneOf [ Parser.token "minute", Parser.token "minutes" ]
        , succeed (Hours amount) |. Parser.oneOf [ Parser.token "hour", Parser.token "hours" ]
        , succeed (Days amount) |. Parser.oneOf [ Parser.token "day", Parser.token "days" ]
        ]


periodParser : Parser Period
periodParser =
    Parser.oneOf [ Parser.int, succeed 1 ]
        |. spaces
        |> Parser.andThen periodUnitParser
