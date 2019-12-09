module Store exposing (IdGenerator(..), Store, StoreState, decode, delete, empty, encode, filterIds, filterValues, get, getNextId, ids, insert, items, map, mapValues, maybeUpdate, nextId, union, update, values)

import Dict exposing (..)
import Json.Decode as JD exposing (Decoder)
import Json.Encode as JE


type alias Store value =
    { items : Dict String value
    , state : StoreState
    , idGenerator : IdGenerator
    }


type alias StoreState =
    Int


type IdGenerator
    = RandomId
    | IncrementalId


get : String -> Store value -> Maybe value
get id store =
    Dict.get id store.items


empty : IdGenerator -> Store value
empty idGenerator =
    { items = Dict.empty, state = 0, idGenerator = idGenerator }


items : Store value -> List ( String, value )
items store =
    Dict.toList store.items


ids : Store value -> List String
ids store =
    Dict.keys store.items


getNextId : Store value -> String
getNextId store =
    nextId store |> Tuple.first


nextId : Store value -> ( String, StoreState )
nextId store =
    -- TODO implement random vs incremental IDs
    ( String.fromInt (store.state + 1), store.state + 1 )


values : Store value -> List value
values store =
    Dict.values store.items


insert : value -> Store value -> Store value
insert value store =
    let
        ( newId, newState ) =
            nextId store

        newItems =
            Dict.insert newId value store.items
    in
    { store | items = newItems, state = newState }


update : String -> (value -> value) -> Store value -> Store value
update id fn store =
    maybeUpdate id (\mv -> Maybe.map fn mv) store


maybeUpdate : String -> (Maybe value -> Maybe value) -> Store value -> Store value
maybeUpdate id fn store =
    let
        newItems =
            Dict.update id fn store.items
    in
    { store | items = newItems }


delete : String -> Store value -> Store value
delete id store =
    { store | items = Dict.remove id store.items }


map : (String -> value -> b) -> Store value -> Store b
map fn store =
    Store (Dict.map fn store.items)
        store.state
        store.idGenerator


mapValues : (value -> b) -> Store value -> Store b
mapValues fn store =
    map (\i v -> fn v) store


filterIds : (String -> Bool) -> Store value -> Store value
filterIds filter store =
    { store | items = Dict.filter (\k v -> filter k) store.items }


filterValues : (value -> Bool) -> Store value -> Store value
filterValues filter store =
    { store | items = Dict.filter (\k v -> filter v) store.items }


union : Store value -> Store value -> Store value
union s2 s1 =
    { s1 | items = Dict.union s1.items s2.items }


encode : (value -> JE.Value) -> Store value -> JE.Value
encode valueEncode store =
    JE.object
        [ ( "state", JE.int store.state )
        , ( "items", JE.dict identity valueEncode store.items )
        , ( "idGenerator"
          , JE.string
                (case store.idGenerator of
                    RandomId ->
                        "random"

                    IncrementalId ->
                        "incremental"
                )
          )
        ]


decode : Decoder value -> Decoder (Store value)
decode valueDecoder =
    JD.map3 Store
        (JD.field "items"
            (JD.dict valueDecoder)
        )
        (JD.field "state" JD.int)
        (JD.field "idGenerator" JD.string
            |> JD.andThen
                (\s ->
                    case s of
                        "incremental" ->
                            JD.succeed IncrementalId

                        _ ->
                            JD.succeed RandomId
                )
        )
