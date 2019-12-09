module Store exposing (SimpleStore, Store, decode, delete, empty, encode, filterIds, filterValues, fromDict, get, getNextId, ids, insert, items, map, mapValues, maybeUpdate, simpleStore, union, update, values)

import Dict exposing (..)
import Json.Decode as JD exposing (Decoder)
import Json.Encode as JE


type alias Store comparable value state =
    { items : Dict comparable value
    , state : state
    , nextId : state -> ( comparable, state )
    }


type alias SimpleStore value =
    Store Int value Int


get : comparable -> Store comparable value state -> Maybe value
get id store =
    Dict.get id store.items


empty : state -> (state -> ( comparable, state )) -> Store comparable value state
empty state nextId =
    { items = Dict.empty, state = state, nextId = nextId }


simpleStore : Store Int value Int
simpleStore =
    { items = Dict.empty, state = 0, nextId = \s -> ( s + 1, s + 1 ) }


fromDict : state -> (state -> ( comparable, state )) -> Dict comparable value -> Store comparable value state
fromDict state nextId dict =
    { items = dict, state = state, nextId = nextId }


items : Store comparable value state -> List ( comparable, value )
items store =
    Dict.toList store.items


ids : Store comparable value state -> List comparable
ids store =
    Dict.keys store.items


getNextId : Store comparable value state -> comparable
getNextId store =
    store.nextId store.state
        |> Tuple.first


values : Store comparable value state -> List value
values store =
    Dict.values store.items


insert : value -> Store comparable value state -> Store comparable value state
insert value store =
    let
        ( newId, newState ) =
            store.nextId store.state

        newItems =
            Dict.insert newId value store.items
    in
    { store | items = newItems, state = newState }


update : comparable -> (value -> value) -> Store comparable value state -> Store comparable value state
update id fn store =
    maybeUpdate id (\mv -> Maybe.map fn mv) store


maybeUpdate : comparable -> (Maybe value -> Maybe value) -> Store comparable value state -> Store comparable value state
maybeUpdate id fn store =
    let
        newItems =
            Dict.update id fn store.items
    in
    { store | items = newItems }


delete : comparable -> Store comparable value state -> Store comparable value state
delete id store =
    { store | items = Dict.remove id store.items }


map : (comparable -> value -> b) -> Store comparable value state -> Store comparable b state
map fn store =
    fromDict
        store.state
        store.nextId
        (Dict.map fn store.items)


mapValues : (value -> b) -> Store comparable value state -> Store comparable b state
mapValues fn store =
    map (\i v -> fn v) store


filterIds : (comparable -> Bool) -> Store comparable value state -> Store comparable value state
filterIds filter store =
    { store | items = Dict.filter (\k v -> filter k) store.items }


filterValues : (value -> Bool) -> Store comparable value state -> Store comparable value state
filterValues filter store =
    { store | items = Dict.filter (\k v -> filter v) store.items }


union : Store comparable value state -> Store comparable value state -> Store comparable value state
union s2 s1 =
    { s1 | items = Dict.union s1.items s2.items }


encode : (comparable -> String) -> (value -> JE.Value) -> (state -> JE.Value) -> Store comparable value state -> JE.Value
encode keyEncode valueEncode stateEncode store =
    JE.object
        [ ( "state", stateEncode store.state )
        , ( "items", JE.dict keyEncode valueEncode store.items )
        ]


decode : (String -> comparable) -> Decoder value -> Decoder state -> (state -> ( comparable, state )) -> Decoder (Store comparable value state)
decode keyMap valueDecoder stateDecoder nextId =
    JD.map3 fromDict
        (JD.field "state" stateDecoder)
        (JD.succeed nextId)
        (JD.field "items"
            (JD.keyValuePairs valueDecoder
                |> JD.map (List.map (\( key, val ) -> ( keyMap key, val )))
                |> JD.map Dict.fromList
            )
        )
