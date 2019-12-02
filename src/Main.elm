port module Main exposing (..)

import Animation
import Animation.Messenger
import Browser
import Ease
import Habit exposing (Habit)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Html.Events exposing (..)
import Json.Decode as JD
import Json.Encode as JE
import Parser
import Period exposing (Period(..), addToPosix, minusFromPosix)
import Time exposing (Posix, posixToMillis)

-- TODO figure out why we can't import this...
rgba r g b a=
    { red = r
    , green = g
    , blue = b
    , alpha = a
    }

main : Program Flags Model Msg
main =
    Browser.document
        { init = init
        , view = \model -> { title = "Tasks", body = [view model] }
        , update = update
        , subscriptions = subscriptions
        }

init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        storage = JD.decodeValue storageDecoder flags.model
            |> Result.withDefault defaultStorageModel
        time = Time.millisToPosix flags.time
    in
    ({ time = time
     , habits = storage.habits
     , options = storage.options
     , uuid = storage.uuid
     , page = HabitList {visibleHabits = storage.habits, pageNumber = 0}
     , pageTransition = Nothing
     , pageLines = 20
    } |> updateVisibleHabits
    , Cmd.none)

-- MODEL
type alias Flags = {time : Int, model: JD.Value}

type alias StorageModel =
    { uuid: Int
    , options: Options
    , habits: List Habit
    }

defaultStorageModel : StorageModel
defaultStorageModel = StorageModel 0 defaultOptions []

storageDecoder: JD.Decoder StorageModel
storageDecoder =
    JD.map3 StorageModel
      (JD.field "uuid" JD.int)
      (JD.field "options" optionsDecoder)
      (JD.field "habits" (JD.list Habit.decoder))

storageEncoder : Model -> JE.Value
storageEncoder model
    = ( JE.object
        [ ("uuid", JE.int model.uuid)
        , ("options", optionsEncoder model.options)
        , ("habits", JE.list Habit.encode model.habits)
    ] )

optionsDecoder: JD.Decoder Options
optionsDecoder =
    JD.map2 Options
        (JD.field "recent" Period.decoder)
        (JD.field "upcoming" Period.decoder)

optionsEncoder: Options -> JE.Value
optionsEncoder options
    = ( JE.object
        [ ("recent", Period.encode options.recent)
        , ("upcoming", Period.encode options.upcoming)
    ] )

type alias Model = 
    { time : Posix 
    , habits : List Habit
    , options : Options
    , page : Page
    , pageTransition : Maybe PageTransition
    , uuid : Int
    , pageLines : Int
    }

type Page
    = HabitList HabitListPage
    | EditHabit EditPage
    | NewHabit NewPage
    | ChangeOptions OptionsPage

type alias PageTransition =
    { previousPage: Page
    , style: Anim
    , above: Bool
    }

initalPageTransitionStyle = (Animation.styleWith (Animation.easing
        { duration = 750
        , ease = Ease.inOutQuart}
    ) [ Animation.right (Animation.px 0) ])
pageTransitionStyle = Animation.interrupt
        [ Animation.to [ Animation.right (Animation.px -510) ]
        , Animation.Messenger.send (SwapPages)
        , Animation.to [ Animation.right (Animation.px 0) ]
        , Animation.Messenger.send (ClearTransition)
        ]

openPageTransition : Page -> PageTransition
openPageTransition page =
    { previousPage = page
    , style = pageTransitionStyle initalPageTransitionStyle
    , above = True
    }

type alias HabitListPage = 
    { visibleHabits : List Habit
    , pageNumber : Int
    }

type alias EditPage =
    { id: Habit.Id
    , description: String
    , tag: String
    , period: String
    }
editPageFromHabit : Habit -> Page
editPageFromHabit habit =
    EditHabit
    { id = habit.id
    , description = habit.description
    , tag = habit.tag
    , period = Period.toString(habit.period) 
    }

type alias NewPage =
    { description: String
    , tag: String
    , period: String
    }
newNewPage : Page
newNewPage =
    NewHabit 
    { description = ""
    , tag = ""
    , period = "1 Day" 
    }

type alias OptionsPage =
    { recent: String
    , upcoming: String
    }
optionsPageFromOptions : Options -> Page
optionsPageFromOptions options =
    ChangeOptions
        { recent = Period.toString(options.recent) 
        , upcoming = Period.toString(options.upcoming) 
        }

type alias Options =
    { recent : Period
    , upcoming : Period
    }
defaultOptions = 
    { recent = Hours 12
    ,upcoming = Hours 12
    }

type alias Anim = Animation.Messenger.State Msg

-- SUBSCRIPTIONS

animationSubscription : Model -> Sub Msg
animationSubscription model =
    case model.pageTransition of
        Just m -> (Animation.subscription AnimatePage [ m.style ])
        Nothing -> (Sub.none)

timeSubscription : Model -> Sub Msg
timeSubscription model = Sub.none
  -- Time.every 1000 Tick

subscriptions : Model -> Sub Msg
subscriptions model =
  Sub.batch [timeSubscription model, animationSubscription model]

-- PORTS
port store : JE.Value -> Cmd msg
storeModel : (Model, Cmd msg) -> (Model, Cmd msg)
storeModel (model, cmd) 
    = (model, Cmd.batch [cmd, store (storageEncoder model)])

-- UPDATE
-- TODO use id?
-- TODO paginate properly

updateVisibleHabits: Model -> Model
updateVisibleHabits model
    = case model.page of
    HabitList habitList -> (
        { model 
        | page = HabitList
            { habitList 
            | visibleHabits = 
                List.filter (viewHabitFilter model.time model.options) model.habits
                |> List.sortBy (\h -> Time.posixToMillis h.nextDue)
                |> List.take model.pageLines
            }
        }
        )
    _ -> model

openHabitListPage: Int -> Model -> Model
openHabitListPage pageNum model
    =
    let
        page = HabitList {visibleHabits = [], pageNumber = pageNum}
        pageTransition = Just (openPageTransition model.page)
    in
    { model | page = page, pageTransition = pageTransition } |> updateVisibleHabits
openHabitList = openHabitListPage 0                

type PageUpdate
    = ChangeEditDescription String
    | ChangeEditTag String
    | ChangeEditPeriod String
    | ChangeNewDescription String
    | ChangeNewTag String
    | ChangeNewPeriod String
    | ChangeOptionsRecent String
    | ChangeOptionsUpcoming String

type Msg 
    = NoOp
    | NoOps String

    -- Subscriptions
    | Tick Time.Posix
    | AnimatePage Animation.Msg
    | SwapPages
    | ClearTransition

    -- Pages
    | OpenEditPage Habit.Id
    | OpenNewPage
    | OpenOptionsPage
    | OpenHabitListPage Int
    | UpdatePage PageUpdate

    -- Options
    | SaveOptions OptionsPage

    -- Tasks
    | DoHabit Habit.Id
    | DoAddHabit NewPage
    | DoDeleteHabit Habit.Id
    | DoEditHabit EditPage


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NoOp -> (model, Cmd.none)
        NoOps s -> (model, Cmd.none)

        Tick time ->
            (
                { model | time = time } |> updateVisibleHabits
                , Cmd.none
            )

        AnimatePage animMsg ->
            case model.pageTransition of
            Nothing -> (model, Cmd.none)
            Just page -> ( 
                let
                    updateStyle s = Animation.Messenger.update animMsg s
                    (style, cmd) = updateStyle page.style
                in
                ( { model | pageTransition = Just {page | style = style} }
                , (cmd)
                )
                )
        
        SwapPages ->
            case model.pageTransition of
            Nothing -> (model, Cmd.none)
            Just transition -> (
                {model | pageTransition = Just {transition | above = not transition.above}}
                , Cmd.none)
        ClearTransition -> 
            ({model | pageTransition = Nothing}, Cmd.none)

        OpenHabitListPage pageNumber ->
            (openHabitListPage pageNumber model, Cmd.none)
        
        OpenEditPage habitId ->
            (
                let
                    habit = List.filter (\h -> h.id == habitId) model.habits
                        |> List.head
                    makePageTransition _ = Just (openPageTransition model.page)
                    page = Maybe.map editPageFromHabit habit
                        |> Maybe.withDefault model.page
                    pageTransition = Maybe.map makePageTransition habit
                        |> Maybe.withDefault model.pageTransition
                in
                { model | page = page, pageTransition = pageTransition }, Cmd.none
            )
        
        OpenNewPage ->
            (
                let
                    pageTransition = Just (openPageTransition model.page)
                in
                { model | page = newNewPage, pageTransition = pageTransition }, Cmd.none
            )
        
        OpenOptionsPage ->
            (
                let
                    pageTransition = Just (openPageTransition model.page)
                in
                { model | page = optionsPageFromOptions model.options, pageTransition = pageTransition}, Cmd.none
            )

        SaveOptions optionsFields ->
            let
                options = model.options
                updatedOptions =
                    { options 
                    | recent = (Period.parse optionsFields.recent)
                    , upcoming = (Period.parse optionsFields.upcoming)
                    }
            in
                ( { model | options = updatedOptions } |> openHabitList
                , Cmd.none
                ) |> storeModel

        DoHabit habitId ->
            (
                let
                    updatedHabits = List.map 
                        (\h -> 
                            if h.id == habitId
                            then Habit.do model.time h 
                            else h
                        ) 
                        model.habits
                in
                    {
                        model | habits = updatedHabits
                    } |> updateVisibleHabits
                    , Cmd.none
            ) |> storeModel
        
        DoAddHabit fields ->
            let
                newHabit = Habit.newHabit
                    model.time
                    fields.description
                    fields.tag
                    (Habit.HabitId model.uuid)
                    (Period.parse fields.period)
            in
                (
                    { model | habits = newHabit :: model.habits
                    , uuid = (model.uuid + 1) } |> openHabitList
                    , Cmd.none
                ) |> storeModel
        
        DoDeleteHabit habitId ->
            (
                { model 
                | habits = List.filter (\h -> (Habit.id h) /= habitId) model.habits
                } |> openHabitList
                , Cmd.none
            ) |> storeModel
        
        DoEditHabit editPage ->
            (
                let
                    updatedHabits = List.map 
                        (\h -> 
                            if h.id == editPage.id
                            then
                                {h | description = editPage.description, tag = editPage.tag, period = (Period.parse editPage.period)} 
                            else h
                        ) 
                        model.habits
                in
                    {
                        model | habits = updatedHabits 
                    } |> openHabitList
                    , Cmd.none
            ) |> storeModel

        UpdatePage pageUpdate -> (
            case (pageUpdate, model.page) of
                (ChangeEditDescription str, EditHabit page) ->
                    (
                        {model | page = EditHabit {page | description = str}}, Cmd.none 
                    )
                (ChangeEditTag str, EditHabit page) ->
                    (
                        {model | page = EditHabit {page | tag = str}}, Cmd.none 
                    )
                (ChangeEditPeriod str, EditHabit page) ->
                    (
                        {model | page = EditHabit {page | period = str}}, Cmd.none 
                    )
                (ChangeNewDescription str, NewHabit page) ->
                    (
                        {model | page = NewHabit {page | description = str}}, Cmd.none 
                    )
                (ChangeNewTag str, NewHabit page) ->
                    (
                        {model | page = NewHabit {page | tag = str}}, Cmd.none 
                    )
                (ChangeNewPeriod str, NewHabit page) ->
                    (
                        {model | page = NewHabit {page | period = str}}, Cmd.none 
                    )
                (ChangeOptionsRecent str, ChangeOptions page) ->
                    (
                        {model | page = ChangeOptions {page | recent = str}}, Cmd.none 
                    )
                (ChangeOptionsUpcoming str, ChangeOptions page) ->
                    (
                        {model | page = ChangeOptions {page | upcoming = str}}, Cmd.none 
                    )
                (_, _) -> (model, Cmd.none)
            )

-- VIEW 
view : Model -> Html Msg
view model =
    div
        [class "page-container"]
        [maybeViewTransition model
        , div
            [class "middle"]
            [viewPage model model.page]
        ]

maybeViewTransition: Model -> Html Msg
maybeViewTransition model =
    Maybe.map
        (viewPageTransition model)
        model.pageTransition |>
        Maybe.withDefault emptyDiv

viewPageTransition : Model -> PageTransition -> Html Msg
viewPageTransition model transition =
    let
        classes = if transition.above then [class "transition-page", class "above"] else [class "transition-page", class "below"]
    in
    div
        (classes ++  Animation.render transition.style)
        [ viewPage model transition.previousPage]

viewPage : Model -> Page -> Html Msg
viewPage model page =
    case page of
        HabitList habitList ->
            (viewHabitsPage model habitList)
        EditHabit editPage ->
            (viewEditingPage model editPage)
        NewHabit newPage ->
            (viewNewPage model newPage)
        ChangeOptions optionsPage ->
            (viewOptionsPage model optionsPage)

-- HABITS VIEW
viewHabitsPage: Model -> HabitListPage -> Html Msg
viewHabitsPage model habits
    = div
        [class "page"]
        [ div
            [class "page-head"]
            [ div
                [class "margin"]
                [ button
                    [ class "add-habit", onClick (OpenOptionsPage) ]
                    [ text "O" ] 
                ]
            ]
        , viewHabits model.pageLines model.time model.options habits.visibleHabits
        , div [class "page-foot"] []
        ]

viewHabits: Int -> Posix -> Options -> List Habit -> Html Msg
viewHabits lines time options habits =
    if (List.length habits) >= lines then
        div
            []
            (List.map (viewHabitLine time options) habits ++
            [button
                [ class "add-habit", onClick (OpenNewPage) ]
                [ text "+" ]] ++
            (List.range (List.length habits) (lines - 1) |> List.map emptyLine))
    else
        div
            []
            (List.map (viewHabitLine time options) habits ++
            [viewLine (button
                [ class "add-habit", onClick (OpenNewPage) ]
                [ text "+" ]) emptyDiv] ++
            (List.range (List.length habits) (lines - 1) |> List.map emptyLine))

viewHabitLine : Posix -> Options -> Habit -> Html Msg
viewHabitLine time options habit =
    viewLine
        (button 
                [ class "habit-edit"
                , onClick (OpenEditPage habit.id)
                ]
                [ text "..." ])
        (button 
                [ class "habit-button"
                , class (if isRecentlyDone time options habit then "habit-done" else "habit-todo")
                , onClick (DoHabit habit.id)
                ]
                [ span 
                    [class "habit-description"]
                    [text habit.description]
                , span 
                    [class "habit-tag"]
                    [text habit.tag] 
                ])

-- EDIT VIEW
viewEditingPage : Model -> EditPage -> Html Msg
viewEditingPage model fields =
    div
        [class "page"]
        ([ div [class "page-head"] [] ] ++
            (habitFieldsView
                fields
                (List.map .tag model.habits) 
                (\s -> UpdatePage (ChangeEditDescription s))
                (\s -> UpdatePage (ChangeEditTag s)) 
                (\s -> UpdatePage (ChangeEditPeriod s)) ++
            [viewLine emptyDiv (div
                [class "button-line"]
                [ button [ onClick (DoEditHabit fields) ] [text "Save"]
                , button [ onClick (DoDeleteHabit fields.id) ] [text "Delete"]
                , button [ onClick (OpenHabitListPage 0) ] [text "Cancel"]
                ])
            ] ++
            ((List.range 6 (model.pageLines - 1) |> List.map emptyLine)) ++
            [div [class "page-foot"] []]))

-- NEW VIEW
viewNewPage : Model -> NewPage -> Html Msg
viewNewPage model fields =
    div
        [class "page"]
        ([ div [class "page-head"] [] ] ++
            (habitFieldsView
                fields
                (List.map .tag model.habits) 
                (\s -> UpdatePage (ChangeNewDescription s))
                (\s -> UpdatePage (ChangeNewTag s)) 
                (\s -> UpdatePage (ChangeNewPeriod s)) ++
            [viewLine emptyDiv (div
                [class "button-line"]
                [ button [ onClick (DoAddHabit fields) ] [text "Save"]
                , button [ onClick (OpenHabitListPage 0) ] [text "Cancel"]
                ])
            ] ++
            ((List.range 6 (model.pageLines - 1) |> List.map emptyLine)) ++
            [div [class "page-foot"] []]))

-- OPTIONS VIEW
viewOptionsPage : Model -> OptionsPage -> Html Msg
viewOptionsPage model fields =
    div
        [class "page"]
        ([ div [class "page-head"] [] ] ++
            [ viewLine emptyDiv (label [] [text "Show upcoming to do"])
            , viewLine emptyDiv (
                input 
                    [value fields.upcoming, list "upcoming-list", onInput (\s -> UpdatePage (ChangeOptionsUpcoming s)) ] []
            )
            , viewLine emptyDiv (label [] [text "Show recently done"])
            , viewLine emptyDiv (
                input 
                    [value fields.recent, list "recent-list", onInput (\s -> UpdatePage (ChangeOptionsRecent s)) ] []
            ), viewLine emptyDiv (div
                [class "button-line"]
                [ button [ onClick (SaveOptions fields) ] [text "Save"]
                , button [ onClick (OpenHabitListPage 0) ] [text "Cancel"]
                ])
            ] ++
            ((List.range 4 (model.pageLines - 1) |> List.map emptyLine)) ++
            [div [class "page-foot"] []
            , periodOptionsView fields.upcoming "upcoming-list"
            , periodOptionsView fields.recent "recent-list"
            ])

-- Other helpers
periodOptionsView : String -> String -> Html Msg
periodOptionsView input for =
    let
        periodUnit = Result.withDefault 
                1
                (Parser.run Parser.int input)
        periodOption period =
            option
                [value (Period.toString period)]
                [text (Period.toString period)]
        periodOptions unit =
            [ periodOption (Minutes unit)
            , periodOption (Hours unit)
            , periodOption (Days unit)
            , periodOption (Weeks unit)
            , periodOption (Months unit)
            ]  
    in
        datalist
            [id for]
            ((periodOptions periodUnit) ++ (periodOptions (periodUnit + 1)))

habitFieldsView fields tags descChange tagChange periodChange
    = let
        tagOption tag = option [value tag] [text tag]
    in
        (List.map (viewLine emptyDiv) [label
            []
            [text "I want to"]
        , input 
            [ placeholder "Do Something", value fields.description, onInput descChange ] []
        , label
            []
            [text "Every"]
        , input 
            [ placeholder "Period", value fields.period, list "period-list", onInput periodChange ] []
        , label
            []
            [text "Tag"]
        , input
            [ placeholder "Todo", value fields.tag, list "tag-list", onInput tagChange ] []
        ]) ++ [datalist
            [id "tag-list"]
            (List.map tagOption tags), periodOptionsView fields.period "period-list"]

-- Line helpers
emptyDiv = (div [] [])

viewLine : Html Msg -> Html Msg -> Html Msg
viewLine margin line = 
    div
        [ class "page-line" ]
        [ div 
            [class "margin"]
            [ margin ]
        , div
            [class "line-content"]
            [ line ]
        ]

emptyLine : a -> Html Msg
emptyLine a = viewLine emptyDiv emptyDiv

-- Due Helpers

isDueSoon: Posix -> Options -> Habit -> Bool
isDueSoon time options habit =
    posixToMillis (Habit.nextDue habit)
        < posixToMillis (addToPosix options.upcoming time)

isRecentlyDone: Posix -> Options -> Habit -> Bool
isRecentlyDone time options habit =
    (Habit.lastDone habit) 
        |> Maybe.map (\l -> posixToMillis l > posixToMillis (minusFromPosix options.recent time))
        |> Maybe.withDefault False

viewHabitFilter: Posix -> Options -> Habit -> Bool
viewHabitFilter time options habit =
    isDueSoon time options habit || isRecentlyDone time options habit