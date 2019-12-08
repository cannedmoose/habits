module Store exposing (SimpleStore, Store, delete, empty, fromDict, getNextId, ids, insert, items, map, mapValues, maybeUpdate, simpleStore, update, values)

import Dict exposing (..)


type alias Store comparable value state =
    { items : Dict comparable value
    , state : state
    , nextId : state -> ( comparable, state )
    }


type alias SimpleStore value =
    Store Int value Int


empty : state -> (state -> ( comparable, state )) -> Store comparable value state
empty state nextId =
    { items = Dict.empty, state = state, nextId = nextId }


simpleStore : Store Int value Int
simpleStore =
    { items = Dict.empty, state = 0, nextId = \s -> ( s + 1, s + 1 ) }


fromDict : Dict comparable value -> state -> (state -> ( comparable, state )) -> Store comparable value state
fromDict dict state nextId =
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
    fromDict (Dict.map fn store.items)
        store.state
        store.nextId


mapValues : (value -> b) -> Store comparable value state -> Store comparable b state
mapValues fn store =
    map (\i v -> fn v) store
