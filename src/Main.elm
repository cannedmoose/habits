port module Main exposing (..)

import Animation
import Animation.Messenger
import Browser
import Dict exposing (Dict)
import Ease
import Habit exposing (Habit, HabitId)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Json.Decode as JD
import Json.Encode as JE
import Parser
import Period exposing (Period(..), addToPosix, minusFromPosix)
import Set exposing (..)
import Store exposing (Store)
import Time exposing (Posix, posixToMillis)


type alias Anim =
    Animation.Messenger.State Msg


pageLines : Int
pageLines =
    20


main : Program Flags Model Msg
main =
    Browser.document
        { init = init
        , view = \model -> { title = "Habits", body = [ view model ] }
        , update = update
        , subscriptions = subscriptions
        }


init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        -- TODO should show error instead of with default
        storage =
            JD.decodeValue storageDecoder flags.model
                |> Result.withDefault defaultStorageModel

        time =
            Time.millisToPosix flags.time
    in
    ( { time = time
      , habits = storage.habits
      , options = storage.options
      , screen = HabitList { page = 0 }
      , screenTransition = Nothing
      }
    , Cmd.none
    )



-- MODEL


type alias Flags =
    { time : Int, model : JD.Value }


type alias StorageModel =
    { options : Options
    , habits : Store Habit
    , version : Int
    }


type alias Model =
    { time : Posix
    , habits : Store Habit
    , options : Options
    , screen : Screen

    -- Single transition (disable interaction during)
    , screenTransition : Maybe ScreenTransition
    }


type alias Options =
    { recent : Period
    , upcoming : Period
    }


defaultOptions =
    { recent = Hours 12
    , upcoming = Hours 12
    }



{-
   TRANSITION AFFECTS IN VS OUT AFFECTS WHICH PAGE GETS STYLED
   IN MEANS MODELS PAGE GETS STYLED
   OUT MEANS TRANSITIONS PAGE GETS STYLED
-}
{-
   Page transition becomes single rather than store
   we disable mouse interaction while transitioning
       Line transitions can still be store.

   Have stack of pages
   Bottom of stack is always the HabitList
   Draw the top of stack

   Save/Cancel/Delete buttons all pop stack
   need to pass info down the stack (eg select a habit, pass habit selected to new)
   OR Select habit -> new habit should pop back to edit/new page that generated select

   --
   SelectHabit sends message
    Cancel - just pop stack
    Select X - pop stack, edit fields in top frame
   New habit sends message
    Cancel - just pop stack
    Save - Pop stack if Select frame send select message

   --


   Maybe stack needs to be typed

   Page =
       HabitList {PageState}
       EditHabitForm {fields}
       NewHabitForm {fields}
       OptionsForm {Fields}
       SelectHabit {PageState} (should highlight currently selected...)
-}
-- App Screens


type Screen
    = HabitList HabitListScreen
    | EditHabit EditHabitScreen
    | CreateHabit CreateHabitScreen
    | SelectHabit SelectHabitScreen
    | EditOptions EditOptionsScreen


type alias HabitListScreen =
    { page : Int }


type alias EditHabitScreen =
    { habitId : HabitId
    , description : String
    , tag : String
    , period : String
    , block : String
    , parent : Screen
    }


type alias CreateHabitScreen =
    { description : String
    , tag : String
    , period : String
    , block : String
    , parent : Screen
    }


type alias SelectHabitScreen =
    { page : Int
    , parent : Screen
    }


type alias EditOptionsScreen =
    { upcoming : String
    , recent : String
    , parent : Screen
    }


type TransitionDirection
    = TransitionIn
    | TransitionOut


type ScreenTransition
    = ScreenTransition
        { previous : Screen
        , style : Anim
        , direction : TransitionDirection
        }


type alias HabitFields a =
    { a
        | description : String
        , tag : String
        , period : String
        , block : String
    }



-- SUBSCRIPTIONS


animationSubscription : Model -> Sub Msg
animationSubscription model =
    case model.screenTransition of
        Nothing ->
            Sub.none

        Just (ScreenTransition { style }) ->
            Animation.subscription
                AnimateScreen
                [ style ]


timeSubscription : Model -> Sub Msg
timeSubscription model =
    Time.every 1000 Tick


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch [ timeSubscription model, animationSubscription model ]



-- PORTS


port store : JE.Value -> Cmd msg


storeModel : ( Model, Cmd msg ) -> ( Model, Cmd msg )
storeModel ( model, cmd ) =
    ( model, Cmd.batch [ cmd, store (storageEncoder model) ] )



-- UPDATE


type Msg
    = NoOp
    | NoOps String
    | Tick Time.Posix
      -- Screen Transition
    | AnimateScreen Animation.Msg
    | ClearTransition
      -- From list screen
    | DoHabit HabitId
      -- Habit Edit
    | OpenHabitEdit HabitId
    | DoDeleteHabit
    | DoEditHabit
      -- Habit Selection
    | OpenHabitSelect
    | DoSelectHabit (Maybe HabitId)
      -- Habit Creation
    | OpenHabitCreate
    | DoCreateHabit
      -- Options
    | OpenEditOptions
    | DoSaveOptions
      -- Form Editing
    | ChangeFormField FormChangeMsg
    | Cancel


type FormChangeMsg
    = ChangeDescription String
    | ChangeTag String
    | ChangePeriod String
    | ToggleBlocked
    | ChangeBlocked String
    | ChangeOptionsRecent String
    | ChangeOptionsUpcoming String


editHabitScreen : Model -> HabitId -> Maybe Screen
editHabitScreen model habitId =
    Store.get habitId model.habits
        |> Maybe.map
            (\habit ->
                EditHabit { habitId = habitId, parent = model.screen, description = habit.description, tag = habit.tag, period = Period.toString habit.period, block = "" }
            )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NoOp ->
            ( model, Cmd.none )

        NoOps s ->
            ( model, Cmd.none )

        Tick time ->
            ( { model | time = time }
            , Cmd.none
            )

        AnimateScreen animMsg ->
            case model.screenTransition of
                Nothing ->
                    ( model, Cmd.none )

                Just (ScreenTransition transition) ->
                    let
                        ( style, cmd ) =
                            Animation.Messenger.update animMsg transition.style
                    in
                    ( { model | screenTransition = Just (ScreenTransition { transition | style = style }) }, cmd )

        ClearTransition ->
            ( { model | screenTransition = Nothing }
            , Cmd.none
            )

        DoHabit habitId ->
            let
                updatedHabit =
                    Store.filterIds ((==) habitId) model.habits
                        |> Store.mapValues (Habit.doHabit model.time)
                        |> Store.union model.habits

                updatedBlocked =
                    Store.filterValues (Habit.isBlocker habitId) updatedHabit
                        |> Store.mapValues (Habit.unblock model.time)
                        |> Store.union updatedHabit
            in
            ( { model
                | habits =
                    Store.filterIds ((==) habitId) model.habits
                        |> Store.mapValues (Habit.doHabit model.time)
                        |> Store.union model.habits
              }
            , Cmd.none
            )
                |> storeModel

        OpenHabitEdit habitId ->
            let
                maybeScreen =
                    editHabitScreen model habitId
            in
            case maybeScreen of
                Nothing ->
                    ( model, Cmd.none )

                Just newScreen ->
                    ( { model
                        | screen = newScreen

                        -- TODO TRANSITION
                        , screenTransition = Nothing
                      }
                    , Cmd.none
                    )

        DoDeleteHabit ->
            case model.screen of
                EditHabit { habitId, parent } ->
                    ( { model
                        | habits =
                            Store.delete habitId model.habits
                                |> Store.mapValues
                                    (\habit ->
                                        if Habit.isBlocker habitId habit then
                                            { habit | block = Habit.Unblocked }

                                        else
                                            habit
                                    )
                        , screen = parent
                        , screenTransition = Nothing
                      }
                    , Cmd.none
                    )
                        |> storeModel

                _ ->
                    ( model, Cmd.none )

        DoEditHabit ->
            case model.screen of
                EditHabit fields ->
                    ( { model
                        | habits =
                            Store.filterIds ((==) fields.habitId) model.habits
                                |> Store.mapValues
                                    (\habit ->
                                        { habit
                                            | description = fields.description
                                            , tag = fields.tag
                                            , period = Period.parse fields.period
                                            , block =
                                                case ( fields.block, habit.block ) of
                                                    -- TODO fix this
                                                    ( _, _ ) ->
                                                        Habit.Unblocked
                                        }
                                    )
                                |> Store.union model.habits
                        , screen = fields.parent
                        , screenTransition = Nothing
                      }
                    , Cmd.none
                    )
                        |> storeModel

                _ ->
                    ( model, Cmd.none )

        OpenHabitSelect ->
            ( { model
                | screen = SelectHabit { page = 0, parent = model.screen }

                -- TODO TRANSITION
                , screenTransition = Nothing
              }
            , Cmd.none
            )

        DoSelectHabit habitId ->
            case model.screen of
                SelectHabit { parent } ->
                    ( { model
                        | screen = parent

                        -- TODO TRANSITION
                        , screenTransition = Nothing
                      }
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        OpenHabitCreate ->
            ( { model
                | screen = CreateHabit { description = "", tag = "", period = "", block = "", parent = model.screen }

                -- TODO TRANSITION
                , screenTransition = Nothing
              }
            , Cmd.none
            )

        DoCreateHabit ->
            case model.screen of
                CreateHabit fields ->
                    let
                        newHabit =
                            Habit.newHabit
                                model.time
                                fields.description
                                fields.tag
                                (Store.getNextId model.habits)
                                (Period.parse fields.period)
                                (Just fields.block)
                    in
                    ( { model
                        | habits = Store.insert newHabit model.habits
                        , screen = fields.parent
                      }
                    , Cmd.none
                    )
                        |> storeModel

                _ ->
                    ( model, Cmd.none )

        OpenEditOptions ->
            ( { model
                | screen = EditOptions { upcoming = "", recent = "", parent = model.screen }
                , screenTransition = Nothing
              }
            , Cmd.none
            )

        DoSaveOptions ->
            case model.screen of
                EditOptions fields ->
                    let
                        options =
                            model.options

                        updatedOptions =
                            { options
                                | recent = Period.parse fields.recent
                                , upcoming = Period.parse fields.upcoming
                            }
                    in
                    ( { model | options = updatedOptions, screen = fields.parent }
                    , Cmd.none
                    )
                        |> storeModel

                _ ->
                    ( model, Cmd.none )

        ChangeFormField formChangeMsg ->
            case ( formChangeMsg, model.screen ) of
                ( ChangeDescription str, EditHabit page ) ->
                    ( { model | screen = EditHabit { page | description = str } }
                    , Cmd.none
                    )

                ( ChangeDescription str, CreateHabit page ) ->
                    ( { model | screen = CreateHabit { page | description = str } }
                    , Cmd.none
                    )

                ( ChangeTag str, EditHabit page ) ->
                    ( { model | screen = EditHabit { page | tag = str } }
                    , Cmd.none
                    )

                ( ChangeTag str, CreateHabit page ) ->
                    ( { model | screen = CreateHabit { page | tag = str } }
                    , Cmd.none
                    )

                ( ChangePeriod str, EditHabit page ) ->
                    ( { model | screen = EditHabit { page | period = str } }
                    , Cmd.none
                    )

                ( ChangePeriod str, CreateHabit page ) ->
                    ( { model | screen = CreateHabit { page | period = str } }
                    , Cmd.none
                    )

                ( ChangeBlocked habitId, EditHabit page ) ->
                    ( { model | screen = EditHabit { page | block = habitId } }
                    , Cmd.none
                    )

                ( ChangeOptionsRecent str, EditOptions page ) ->
                    ( { model | screen = EditOptions { page | recent = str } }
                    , Cmd.none
                    )

                ( ChangeOptionsUpcoming str, EditOptions page ) ->
                    ( { model | screen = EditOptions { page | upcoming = str } }
                    , Cmd.none
                    )

                ( _, _ ) ->
                    ( model, Cmd.none )

        Cancel ->
            let
                prev =
                    case model.screen of
                        HabitList _ ->
                            model.screen

                        EditHabit { parent } ->
                            parent

                        CreateHabit { parent } ->
                            parent

                        EditOptions { parent } ->
                            parent

                        SelectHabit { parent } ->
                            parent
            in
            ( { model | screen = prev }, Cmd.none )


habitOrderer : Model -> Habit -> Int
habitOrderer model habit =
    if shouldBeMarkedAsDone model habit then
        Maybe.withDefault model.time habit.lastDone
            |> Time.posixToMillis

    else
        -1 * (Time.posixToMillis habit.nextDue - Time.posixToMillis model.time)


visibleHabits : Model -> Store Habit
visibleHabits model =
    Store.filterValues (viewHabitFilter model) model.habits



-- VIEW


view : Model -> Html Msg
view model =
    div
        [ class "page-container" ]
        -- TODO maybe view transition
        [ div
            [ class "middle" ]
            [ viewPage model model.screen ]
        ]


viewPageTransition : Model -> ScreenTransition -> Html Msg
viewPageTransition model (ScreenTransition transition) =
    let
        classes =
            [ class "transition-page" ]
    in
    div
        (classes ++ Animation.render transition.style)
        [ viewPage
            model
            transition.previous
        ]


viewPage : Model -> Screen -> Html Msg
viewPage model page =
    case page of
        HabitList habitList ->
            viewHabitsListPage model habitList

        EditHabit editPage ->
            viewEditingPage model editPage

        CreateHabit newPage ->
            viewNewPage model newPage

        EditOptions optionsPage ->
            viewOptionsPage model optionsPage

        -- TODO
        SelectHabit habitSelect ->
            viewHabitsSelectPage model habitSelect



-- HABITS VIEW


viewHabitsListPage : Model -> HabitListScreen -> Html Msg
viewHabitsListPage model habits =
    div
        [ class "page" ]
        [ div
            [ class "page-head" ]
            [ div
                [ class "margin" ]
                [ button
                    [ class "add-habit", onClick OpenEditOptions ]
                    [ text "-" ]
                ]
            ]
        , viewHabits model habits.page
        , div [ class "page-foot" ] []
        ]


viewHabits : Model -> Int -> Html Msg
viewHabits model pageNumber =
    -- TODO handle multiple pages of habits
    let
        { time, options, habits } =
            model

        visible =
            visibleHabits model
                |> Store.values
                |> List.sortBy (habitOrderer model)
                |> List.drop (pageNumber * pageLines)
                |> List.take pageLines
    in
    div
        []
        (List.map (viewHabitLine model) visible
            ++ viewLine
                (button
                    [ class "add-habit", onClick OpenHabitCreate ]
                    [ text "+" ]
                )
                emptyDiv
            :: (List.range (List.length visible) (pageLines - 1)
                    |> List.map emptyLine
               )
        )


viewHabitLine : Model -> Habit -> Html Msg
viewHabitLine model habit =
    viewLine
        (button
            [ class "habit-edit"
            , onClick (OpenHabitEdit habit.id)
            ]
            [ text "..." ]
        )
        (button
            [ class "habit-button"
            , class
                (if shouldBeMarkedAsDone model habit then
                    "habit-done"

                 else
                    "habit-todo"
                )
            , onClick (DoHabit habit.id)
            ]
            [ span
                [ class "habit-description" ]
                [ text habit.description ]
            , span
                [ class "habit-tag" ]
                [ text habit.tag ]
            ]
        )



-- EDIT VIEW


viewEditingPage : Model -> EditHabitScreen -> Html Msg
viewEditingPage model fields =
    div
        [ class "page" ]
        ([ div [ class "page-head" ] []
         , habitFieldsView
            fields
            (Store.values model.habits)
            (Just fields.habitId)
         , viewLineContent
            (div
                [ class "button-line" ]
                [ button [ onClick DoEditHabit ] [ text "Save" ]
                , button [ onClick DoDeleteHabit ] [ text "Delete" ]
                , button [ onClick Cancel ] [ text "Cancel" ]
                ]
            )
         ]
            ++ (List.range 8 (pageLines - 1) |> List.map emptyLine)
            ++ [ div [ class "page-foot" ] [] ]
        )



-- NEW VIEW


viewNewPage : Model -> CreateHabitScreen -> Html Msg
viewNewPage model fields =
    div
        [ class "page" ]
        ([ div [ class "page-head" ] []
         , habitFieldsView
            fields
            (Store.values model.habits)
            Nothing
         , viewLineContent
            (div
                [ class "button-line" ]
                [ button [ onClick DoCreateHabit ] [ text "Save" ]
                , button [ onClick Cancel ] [ text "Cancel" ]
                ]
            )
         ]
            ++ (List.range 8 (pageLines - 1) |> List.map emptyLine)
            ++ [ div [ class "page-foot" ] [] ]
        )



-- OPTIONS VIEW


viewOptionsPage : Model -> EditOptionsScreen -> Html Msg
viewOptionsPage model fields =
    div
        [ class "page" ]
        ([ div [ class "page-head" ]
            [ div
                [ class "margin" ]
                [ button
                    [ class "add-habit", onClick OpenEditOptions ]
                    [ text "-" ]
                ]
            ]
         , viewLineContent (label [] [ text "Show upcoming" ])
         , viewLineContent
            (input
                [ value fields.upcoming, list "upcoming-list", onInput (\s -> ChangeFormField (ChangeOptionsUpcoming s)) ]
                []
            )
         , viewLineContent (label [] [ text "Show recently done" ])
         , viewLineContent
            (input
                [ value fields.recent, list "recent-list", onInput (\s -> ChangeFormField (ChangeOptionsRecent s)) ]
                []
            )
         , viewLineContent
            (div
                [ class "button-line" ]
                [ button [ onClick DoSaveOptions ] [ text "Save" ]
                , button [ onClick Cancel ] [ text "Cancel" ]
                ]
            )
         ]
            ++ (List.range 4 (pageLines - 1) |> List.map emptyLine)
            ++ [ div [ class "page-foot" ] []
               , periodOptionsView fields.upcoming "upcoming-list"
               , periodOptionsView fields.recent "recent-list"
               ]
        )



-- Other helpers


periodOptionsView : String -> String -> Html Msg
periodOptionsView input for =
    let
        periodUnit =
            Result.withDefault
                1
                (Parser.run Parser.int input)

        periodOption period =
            option
                [ value (Period.toString period) ]
                [ text (Period.toString period) ]

        periodOptions unit =
            [ periodOption (Minutes unit)
            , periodOption (Hours unit)
            , periodOption (Days unit)
            , periodOption (Weeks unit)
            , periodOption (Months unit)
            ]
    in
    datalist
        [ id for ]
        (periodOptions periodUnit ++ periodOptions (periodUnit + 1))



-- TODO FIX THIS


habitFieldsView :
    HabitFields a
    -> List Habit
    -> Maybe HabitId
    -> Html Msg
habitFieldsView fields habits maybeHabit =
    let
        tagOption tag =
            option [ value tag ] [ text tag ]

        tagOptions =
            List.map .tag habits |> List.map tagOption

        filteredHabits =
            case maybeHabit of
                Nothing ->
                    habits

                Just habitId ->
                    List.filter (\h -> habitId /= h.id) habits
    in
    div
        []
        [ asLineContent label
            []
            [ text "I want to" ]
        , asLineContent input
            [ placeholder "Do Something", value fields.description, onInput (\s -> ChangeFormField (ChangeDescription s)) ]
            []
        , asLineContent label
            []
            [ text "every" ]
        , asLineContent input
            [ placeholder "Period", value fields.period, list "period-list", onInput (\s -> ChangeFormField (ChangePeriod s)) ]
            []
        , asLineContent label
            []
            [ text "after" ]
        , asLineContent button
            [ onClick OpenHabitSelect ]
            [ text "last time" ]
        , asLineContent label
            []
            [ text "Tag" ]
        , asLineContent input
            [ placeholder "Todo", value fields.tag, list "tag-list", onInput (\s -> ChangeFormField (ChangeTag s)) ]
            []
        , datalist
            [ id "tag-list" ]
            tagOptions
        , periodOptionsView fields.period "period-list"
        ]


viewHabitsSelectPage : Model -> SelectHabitScreen -> Html Msg
viewHabitsSelectPage model habits =
    div
        [ class "page" ]
        [ div
            [ class "page-head" ]
            [ div
                [ class "margin" ]
                []
            , div
                [ class "page-content" ]
                [ text "Select Habit" ]
            ]
        , viewHabitSelect model habits.page
        , div [ class "page-foot" ] []
        ]


viewHabitSelect : Model -> Int -> Html Msg
viewHabitSelect model pageNumber =
    -- TODO handle multiple pages of habits
    let
        { time, options, habits } =
            model

        visible =
            Store.values model.habits
                |> List.sortBy .description
                |> List.drop (pageNumber * pageLines)
                |> List.take pageLines
    in
    div
        []
        (viewLine
            emptyDiv
            (button
                [ class "habit-button"
                , onClick (DoSelectHabit Nothing)
                ]
                [ span
                    [ class "habit-description" ]
                    [ text "last time" ]
                ]
            )
            :: (List.map (viewHabitLine2 model) visible
                    ++ viewLine
                        (button
                            [ class "add-habit", onClick OpenHabitCreate ]
                            [ text "+" ]
                        )
                        (button
                            [ class "add-habit", onClick Cancel ]
                            [ text "Cancel" ]
                        )
                    :: (List.range (List.length visible) (pageLines - 1)
                            |> List.map emptyLine
                       )
               )
        )


viewHabitLine2 : Model -> Habit -> Html Msg
viewHabitLine2 model habit =
    viewLine
        emptyDiv
        (button
            [ class "habit-button"
            , onClick (DoSelectHabit (Just habit.id))
            ]
            [ span
                [ class "habit-description" ]
                [ text habit.description ]
            , span
                [ class "habit-tag" ]
                [ text habit.tag ]
            ]
        )



-- Line helpers


emptyDiv =
    div [] []


viewLine : Html Msg -> Html Msg -> Html Msg
viewLine margin line =
    div
        [ class "page-line" ]
        [ div
            [ class "margin" ]
            [ margin ]
        , div
            [ class "line-content" ]
            [ line ]
        ]


viewLineContent : Html Msg -> Html Msg
viewLineContent line =
    viewLine emptyDiv line


asLineContent : (b -> c -> Html Msg) -> b -> c -> Html Msg
asLineContent el attribs children =
    viewLine emptyDiv (el attribs children)


emptyLine : a -> Html Msg
emptyLine a =
    viewLine emptyDiv emptyDiv



-- Due Helpers
-- TODO move some of these into habit


isDueSoon : Model -> Habit -> Bool
isDueSoon { time, options } habit =
    posixToMillis habit.nextDue
        < posixToMillis (addToPosix options.upcoming time)


isRecentlyDone : Model -> Habit -> Bool
isRecentlyDone { time, options } habit =
    habit.lastDone
        |> Maybe.map (\l -> posixToMillis l > posixToMillis (minusFromPosix options.recent time))
        |> Maybe.withDefault False


shouldBeMarkedAsDone : Model -> Habit -> Bool
shouldBeMarkedAsDone model habit =
    if Habit.isBlocked habit then
        True

    else
        not (isDueSoon model habit)


viewHabitFilter : Model -> Habit -> Bool
viewHabitFilter model habit =
    let
        due =
            isDueSoon model habit

        recent =
            isRecentlyDone model habit
    in
    if Habit.isBlocked habit then
        recent

    else
        due || recent



-- Transitions
{-
   initalPageTransitionStyle =
       Animation.styleWith
           (Animation.easing
               { duration = 750
               , ease = Ease.inOutQuart
               }
           )
           [ Animation.right (Animation.px 0) ]


   pageTransitionStyle model =
       Animation.interrupt
           [ Animation.to [ Animation.right (Animation.px -510) ]
           , Animation.Messenger.send (SwapPages (Store.getNextId model.pageTransitions))
           , Animation.to [ Animation.right (Animation.px 0) ]
           , Animation.Messenger.send (ClearTransition (Store.getNextId model.pageTransitions))
           ]


   openPageTransition : Model -> PageTransition
   openPageTransition model =
       Transition
           { previous = { model | pageTransitions = Store.empty Store.IncrementalId }
           , style = pageTransitionStyle model initalPageTransitionStyle
           , above = True
           }

-}
-- Encode/Decode


defaultStorageModel : StorageModel
defaultStorageModel =
    StorageModel defaultOptions (Store.empty Store.RandomId) 0


habitDictFromList : List Habit -> Dict HabitId Habit
habitDictFromList habits =
    List.map (\h -> ( h.id, h )) habits
        |> Dict.fromList


storageDecoder : JD.Decoder StorageModel
storageDecoder =
    JD.map3 StorageModel
        (JD.field "options" optionsDecoder)
        (JD.field "habits" (Store.decode Habit.decoder))
        (JD.succeed 0)


storageEncoder : Model -> JE.Value
storageEncoder model =
    JE.object
        [ ( "options", optionsEncoder model.options )
        , ( "habits", Store.encode Habit.encode model.habits )
        , ( "version", JE.int 0 )
        ]


optionsDecoder : JD.Decoder Options
optionsDecoder =
    JD.map2 Options
        (JD.field "recent" Period.decoder)
        (JD.field "upcoming" Period.decoder)


optionsEncoder : Options -> JE.Value
optionsEncoder options =
    JE.object
        [ ( "recent", Period.encode options.recent )
        , ( "upcoming", Period.encode options.upcoming )
        ]



-- UTILS


flip : (a -> b -> c) -> b -> a -> c
flip fn b a =
    fn a b


curry : (( a, b ) -> c) -> a -> b -> c
curry fn a b =
    fn ( a, b )


uncurry : (a -> b -> c) -> ( a, b ) -> c
uncurry fn ( a, b ) =
    fn a b



-- VIEW Page
-- TODO maybe save this for later
-- work on storage first...
-- or how to model current page and a page stack...
{-

   type alias PageConfig =
       { showOptions : Bool
       , title : String
       , footer : PageLine
       , nLines : Int
       }


   type alias PageState =
       { pageNumber : Int
       }


   type alias PageLine =
       ( Html Msg, Html Msg )


   type alias PageLines =
       List PageLine


   cullPageLines : PageConfig -> PageState -> PageLines -> PageLines
   cullPageLines { nLines } { pageNumber } lines =
       lines
           |> List.drop (pageNumber * nLines)
           |> List.take nLines


   viewPageLine : PageLine -> Html Msg
   viewPageLine ( margin, content ) =
       div
           [ class "page-line" ]
           [ div
               [ class "margin" ]
               [ margin ]
           , div
               [ class "line-content" ]
               [ content ]
           ]


   viewPageLines : PageLines -> PageLine -> Html Msg
   viewPageLines lines footer =
       div
           [ class "page-lines" ]
           (List.map viewPageLine
               (lines
                   ++ [ footer ]
               )
           )


   viewPageFooter : PageConfig -> PageState -> PageLines -> Html Msg
   viewPageFooter { nLines } { pageNumber } lines =
       -- TODO hook these up to next/prev pages
       div
           [ class "page-foot" ]
           [ div
               [ class "margin" ]
               (if pageNumber > 0 then
                   [ button
                       [ class "add-habit", onClick OpenOptionsPage ]
                       [ text "<" ]
                   ]

                else
                   []
               )
           , div
               [ class "line-content" ]
               (if List.length lines > nLines then
                   [ button
                       [ class "add-habit", onClick OpenOptionsPage ]
                       [ text ">" ]
                   ]

                else
                   []
               )
           ]



   -- Page config is static (in view)
   -- Page state is from the model
   -- PageLines is generated from model
   -- TODO make habit page etc in this new form...


   viewPage123 : PageConfig -> PageState -> PageLines -> Html Msg
   viewPage123 config state lines =
       div
           [ class "page" ]
           [ div
               [ class "page-head" ]
               [ div
                   [ class "margin" ]
                   (if config.showOptions then
                       [ button
                           [ class "add-habit", onClick OpenOptionsPage ]
                           [ text "-" ]
                       ]

                    else
                       []
                   )
               , div
                   [ class "line-content" ]
                   [ text config.title ]
               ]
           , viewPageLines (cullPageLines config state lines) config.footer
           , div [ class "page-foot" ] []
           ]
-}
