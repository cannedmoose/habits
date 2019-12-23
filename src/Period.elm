module Period exposing (Period(..), addS, addToPosix, day, decoder, encode, fromDelta, fromString, hour, minusFromPosix, minute, month, parse, periodParser, periodUnitParser, toMillis, toString, week)

import Json.Decode as JD exposing (Decoder)
import Json.Encode as Encode
import Parser exposing ((|.), (|=), Parser, int, spaces, succeed)
import Time exposing (Posix)


type Period
    = Immediate
    | Minutes Int
    | Hours Int
    | Days Int
    | Weeks Int
    | Months Int


minute : Period
minute =
    Minutes 1


hour : Period
hour =
    Minutes 59


day : Period
day =
    Hours 23


week : Period
week =
    Days 7


month : Period
month =
    Months 1


addToPosix : Period -> Posix -> Posix
addToPosix period time =
    Time.millisToPosix (Time.posixToMillis time + toMillis period)


minusFromPosix : Period -> Posix -> Posix
minusFromPosix period time =
    Time.millisToPosix (Time.posixToMillis time - toMillis period)


fromDelta : Posix -> Posix -> Period
fromDelta t1 t2 =
    let
        delta =
            Time.posixToMillis t2 - Time.posixToMillis t1
    in
    if delta < toMillis minute then
        Immediate

    else if delta < toMillis hour then
        Minutes (delta // toMillis minute)

    else if delta < toMillis day then
        Hours (delta // toMillis hour)

    else if delta < toMillis week then
        Days (delta // toMillis day)

    else if delta < toMillis month then
        Weeks (delta // toMillis week)

    else
        Months (delta // toMillis month)


toMillis : Period -> Int
toMillis period =
    case period of
        Immediate ->
            0

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
        Immediate ->
            "Now"

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
    if amount == 0 then
        Immediate

    else
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
        , succeed (Minutes amount) |. Parser.oneOf [ Parser.token "minute", Parser.token "minutes" ]
        , succeed Immediate |. Parser.token "now"
        , succeed (Months amount) |. Parser.oneOf [ Parser.token "month", Parser.token "months" ]
        , succeed (Hours amount) |. Parser.oneOf [ Parser.token "hour", Parser.token "hours" ]
        , succeed (Days amount) |. Parser.oneOf [ Parser.token "day", Parser.token "days" ]
        ]


periodParser : Parser Period
periodParser =
    Parser.oneOf [ Parser.int, succeed 1 ]
        |. spaces
        |> Parser.andThen periodUnitParser
