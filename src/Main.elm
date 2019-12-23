port module Main exposing (..)

import Animation
import Animation.Messenger
import Browser
import Browser.Dom as Dom
import Dict exposing (Dict)
import Ease
import Habit exposing (Habit, HabitId)
import HabitStore exposing (..)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Json.Decode as JD
import Json.Encode as JE
import Page exposing (..)
import Parser
import Period exposing (Period(..), addToPosix, minusFromPosix)
import Random
import Random.Char
import Random.String
import Set
import Task
import Time exposing (Posix, posixToMillis)


type alias Anim =
    Animation.Messenger.State Msg


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
        -- TODO Show error when decoding fails
        storage =
            JD.decodeValue storageDecoder flags.model

        _ =
            case storage of
                Err _ ->
                    ""

                -- Debug.log "Decode error " err |> (\_ -> "")
                _ ->
                    ""

        storage2 =
            Result.withDefault defaultStorageModel storage

        time =
            Time.millisToPosix flags.time
    in
    ( { time = time
      , habits = applyDeltas Dict.empty storage2.habits
      , options = storage2.options
      , screen = NoScreen
      , screenTransition = Nothing
      , animations = Dict.empty
      , modal = NoModal
      , pageElement = Nothing
      }
    , getPageElement
    )



-- MODEL


type alias Flags =
    { time : Int
    , model : JD.Value
    }


type alias StorageModel =
    { options : Options
    , habits : List HabitDelta
    , version : Int
    }


type alias Model =
    { time : Posix
    , habits : Dict HabitId Habit
    , options : Options
    , screen : Screen
    , screenTransition : Maybe ScreenTransition
    , animations : Dict String Anim
    , modal : Modal

    -- TODO maybe move pageElement into screen?
    , pageElement : Maybe Dom.Element
    }


type alias Options =
    { recent : Period
    , upcoming : Period
    , seenModals : List Modal
    }


type Modal
    = NoModal
    | IntroModal -- Opened on home screen BEFORE ANYTHING (and haven;t seend before)
    | FirstHabitModal -- Opened on home screen after page transitions in if no habits exist (and haven;t seend before)
    | AddingHabitModal -- Opened on add screen if no hobits exist (and haven't seen before)
    | DoHabitModal -- Opened on home screen if habits exist (and haven;t seend before)
    | OpenOptionsModal -- Opened on home screen after habit is done (and haven't seen before)


defaultOptions : Options
defaultOptions =
    { recent = Hours 12
    , upcoming = Hours 12
    , seenModals = []
    }



-- Screens


type Screen
    = HabitList HabitListScreen
    | EditHabit EditHabitScreen
    | CreateHabit CreateHabitScreen
    | SelectHabit SelectHabitScreen
    | EditOptions EditOptionsScreen
    | NoScreen


type alias HabitListScreen =
    { page : Int }


type alias FormFields =
    Dict String String


type alias EditHabitScreen =
    { habitId : HabitId
    , fields : FormFields
    , deltas : List HabitStore.HabitFieldChange
    , parent : Screen
    }


type alias CreateHabitScreen =
    { fields : FormFields
    , deltas : List HabitStore.HabitFieldChange
    , parent : Screen
    }


type alias HabitForm a =
    { a
        | fields : FormFields
        , deltas : List HabitStore.HabitFieldChange
    }


type alias PartialHabit =
    { id : Maybe HabitId
    , description : String
    }


type alias SelectHabitScreen =
    { page : Int
    , selected : Maybe HabitId
    , forHabit : PartialHabit
    , parent : Screen
    }


type alias EditOptionsScreen =
    { upcoming : String
    , recent : String
    , parent : Screen
    }


type alias ScreenModel a =
    { a
        | time : Posix
        , habits : Dict HabitId Habit
        , options : Options
        , screen : Screen
    }


type TransitionDirection
    = TransitionIn
    | TransitionOut


type ScreenTransition
    = ScreenTransition
        { time : Posix
        , habits : Dict HabitId Habit
        , options : Options
        , screen : Screen
        , direction : TransitionDirection
        }



-- SUBSCRIPTIONS


animationSubscription : Model -> Sub Msg
animationSubscription model =
    Animation.subscription
        AnimateScreen
        (Dict.values
            model.animations
        )


timeSubscription : Model -> Sub Msg
timeSubscription _ =
    Time.every 1000 Tick


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch [ timeSubscription model, animationSubscription model ]


getPageElement : Cmd Msg
getPageElement =
    -- TODO Subscribe to viewport change so we can redo this
    Task.attempt NewPageElement (Dom.getElement "habits-view")



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
    | OpenHabitSelect PartialHabit (Maybe HabitId)
    | DoSelectHabit (Maybe HabitId)
      -- Habit Creation
    | OpenHabitCreate
    | DoCreateHabit (Maybe HabitId)
      -- Options
    | DoSaveOptions
      -- Form Editing
    | ChangeFormField String String
    | BlurFormField String
    | Cancel
    | NewPageElement (Result Dom.Error Dom.Element)
    | CloseModal
    | ClearModal
    | PageAction PageMessage
    | DoClearData
    | DoToggleHelp


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case ( model.screen, msg ) of
        ( _, NoOp ) ->
            ( model, Cmd.none )

        ( _, Tick time ) ->
            let
                updatedModel =
                    { model | time = time }

                shouldFade =
                    -- TODO this should be based on order as well...
                    visibleHabits updatedModel /= visibleHabits model
            in
            ( if shouldFade then
                fadeTransition model |> (\m -> { m | time = time })

              else
                updatedModel
            , Cmd.none
            )

        ( _, AnimateScreen animMsg ) ->
            let
                updated =
                    Dict.map (\_ v -> Animation.Messenger.update animMsg v) model.animations

                cmds =
                    Dict.values updated |> List.map Tuple.second

                newAnimations =
                    Dict.map (\_ v -> Tuple.first v) updated
            in
            ( { model | animations = newAnimations }, Cmd.batch cmds )

        ( _, Cancel ) ->
            let
                prev =
                    case model.screen of
                        HabitList _ ->
                            model.screen

                        NoScreen ->
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
            ( flipOffRight prev model
            , Cmd.none
            )

        ( _, ClearTransition ) ->
            ( { model | screenTransition = Nothing }
            , Cmd.none
            )
                |> afterTransitionModalUpdate

        ( _, DoHabit habitId ) ->
            let
                newStore =
                    Dict.get habitId model.habits
                        |> Maybe.map (doHabitDeltas model.habits model.time)
                        |> Maybe.map (applyDeltas model.habits)
                        |> Maybe.withDefault model.habits

                transitionModel =
                    fadeTransition model
            in
            ( { transitionModel | habits = newStore }
                |> afterDoHabitModalUpdate
            , Cmd.none
            )
                |> storeModel

        ( _, OpenHabitEdit habitId ) ->
            case editHabitScreen model habitId of
                Nothing ->
                    ( model, Cmd.none )

                Just newScreen ->
                    ( flipOn newScreen model
                    , Cmd.none
                    )

        ( _, OpenHabitSelect forHabit selected ) ->
            ( flipOn
                (SelectHabit
                    { page = 0
                    , selected = selected
                    , forHabit = forHabit
                    , parent = model.screen
                    }
                )
                model
            , Cmd.none
            )

        ( _, OpenHabitCreate ) ->
            ( slideFromTopTransition
                (CreateHabit
                    { fields = habitToFields (HabitStore.emptyHabit "")
                    , deltas = []
                    , parent = model.screen
                    }
                )
                model
            , Cmd.none
            )

        ( _, PageAction OpenOptions ) ->
            ( slideFromTopTransition
                (EditOptions
                    { upcoming = Period.toString model.options.upcoming
                    , recent = Period.toString model.options.recent
                    , parent = model.screen
                    }
                )
                model
            , Cmd.none
            )

        ( NoScreen, NewPageElement (Ok el) ) ->
            let
                options =
                    model.options

                showModal =
                    not (List.member IntroModal model.options.seenModals)
            in
            if showModal then
                ( { model
                    | pageElement = Just el
                    , modal = IntroModal
                    , options = { options | seenModals = IntroModal :: options.seenModals }
                  }
                    |> modalInTransition
                , Cmd.none
                )

            else
                ( { model
                    | pageElement = Just el
                  }
                    |> slideFromTopTransition (HabitList { page = 0 })
                , Cmd.none
                )

        ( _, NewPageElement elResult ) ->
            case elResult of
                Ok el ->
                    ( { model | pageElement = Just el }, Cmd.none )

                _ ->
                    ( { model | pageElement = Nothing }, Cmd.none )

        ( _, CloseModal ) ->
            ( modalOutTransition model
            , Cmd.none
            )

        ( _, ClearModal ) ->
            ( { model
                | modal = NoModal
                , animations =
                    model.animations
                        |> Dict.remove "modal-fg"
                        |> Dict.remove "modal-bg"
              }
                |> afterModalModelUpdate model.modal
            , Cmd.none
            )

        ( EditHabit screen, DoDeleteHabit ) ->
            let
                newStore =
                    deleteHabitDeltas
                        model.habits
                        model.time
                        screen.habitId
                        |> applyDeltas model.habits
            in
            ( { model
                | habits = newStore
              }
                |> slideOffbottom screen.parent
            , Cmd.none
            )
                |> storeModel

        ( EditHabit screen, DoEditHabit ) ->
            let
                newStore =
                    editHabitDeltas
                        model.habits
                        model.time
                        screen.habitId
                        screen.deltas
                        |> applyDeltas model.habits
            in
            ( { model
                | habits = newStore
              }
                |> flipOffRight screen.parent
            , Cmd.none
            )
                |> storeModel

        ( SelectHabit { parent }, DoSelectHabit maybeHabitId ) ->
            let
                updateScreen screen =
                    case maybeHabitId of
                        Just habitId ->
                            { screen
                                | fields = Dict.insert "block" habitId screen.fields
                                , deltas =
                                    HabitStore.buildFieldChanges
                                        screen.deltas
                                        (HabitStore.BlockChange (Habit.Blocker habitId True))
                            }

                        Nothing ->
                            { screen
                                | fields = Dict.remove "block" screen.fields
                                , deltas =
                                    HabitStore.buildFieldChanges
                                        screen.deltas
                                        (HabitStore.BlockChange Habit.Unblocked)
                            }
            in
            ( case parent of
                EditHabit screen ->
                    flipOffRight (EditHabit (updateScreen screen)) model

                CreateHabit screen ->
                    flipOffRight (CreateHabit (updateScreen screen)) model

                _ ->
                    flipOffRight parent model
            , Cmd.none
            )

        ( CreateHabit screen, DoCreateHabit maybeId ) ->
            case maybeId of
                Nothing ->
                    let
                        idGenerator =
                            Random.map Just (Random.String.string 8 Random.Char.alchemicalSymbol)
                    in
                    ( model, Random.generate DoCreateHabit idGenerator )

                Just id ->
                    let
                        newStore =
                            addHabitDeltas
                                model.habits
                                (Period.minusFromPosix (Minutes 1) model.time)
                                id
                                screen.deltas
                                |> applyDeltas model.habits
                    in
                    ( { model | habits = newStore }
                        |> flipOffRight screen.parent
                    , Cmd.none
                    )
                        |> storeModel

        ( EditOptions screen, DoSaveOptions ) ->
            let
                { options } =
                    model

                updatedOptions =
                    { options
                        | recent = Period.parse screen.recent
                        , upcoming = Period.parse screen.upcoming
                    }
            in
            ( { model | options = updatedOptions }
                |> flipOffRight screen.parent
            , Cmd.none
            )
                |> storeModel

        ( EditHabit page, ChangeFormField field val ) ->
            ( { model | screen = EditHabit (updateHabitFormFields page field val) }
            , Cmd.none
            )

        ( CreateHabit page, ChangeFormField field val ) ->
            ( { model | screen = CreateHabit (updateHabitFormFields page field val) }
            , Cmd.none
            )

        ( EditOptions page, ChangeFormField field val ) ->
            case field of
                "recent" ->
                    ( { model | screen = EditOptions { page | recent = val } }
                    , Cmd.none
                    )

                "upcoming" ->
                    ( { model | screen = EditOptions { page | upcoming = val } }
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        ( HabitList screen, PageAction (ChangePage page) ) ->
            ( if page < screen.page then
                flipOffRight (HabitList { screen | page = page }) model

              else
                flipOn (HabitList { screen | page = page }) model
            , Cmd.none
            )

        ( SelectHabit screen, PageAction (ChangePage page) ) ->
            ( if page < screen.page then
                flipOffRight (SelectHabit { screen | page = page }) model

              else
                flipOn (SelectHabit { screen | page = page }) model
            , Cmd.none
            )

        ( EditOptions screen, DoClearData ) ->
            ( { model | habits = Dict.empty }
                |> flipOffRight screen.parent
            , Cmd.none
            )
                |> storeModel

        ( _, DoToggleHelp ) ->
            let
                options =
                    model.options

                seenAllHelp =
                    List.length options.seenModals == 5
            in
            if seenAllHelp then
                ( { model | options = { options | seenModals = [ IntroModal ] } }, Cmd.none ) |> storeModel

            else
                ( { model
                    | options =
                        { options
                            | seenModals =
                                [ IntroModal
                                , FirstHabitModal
                                , AddingHabitModal
                                , DoHabitModal
                                , OpenOptionsModal
                                ]
                        }
                  }
                , Cmd.none
                )
                    |> storeModel

        ( _, _ ) ->
            ( model, Cmd.none )


habitToFields : Habit -> FormFields
habitToFields habit =
    let
        blocker =
            Habit.blockerId habit
                |> Maybe.map (\id -> ( "block", id ))
                |> Maybe.map List.singleton
                |> Maybe.withDefault []
    in
    Dict.fromList
        ([ ( "description", habit.description )
         , ( "tag", habit.tag )
         , ( "period", Period.toString habit.period )
         ]
            ++ blocker
        )


editHabitScreen : Model -> HabitId -> Maybe Screen
editHabitScreen model habitId =
    Dict.get habitId model.habits
        |> Maybe.map
            (\habit ->
                EditHabit
                    { habitId = habitId
                    , parent = model.screen
                    , deltas = []
                    , fields = habitToFields habit
                    }
            )


updateHabitFormFields : HabitForm a -> String -> String -> HabitForm a
updateHabitFormFields page field val =
    case field of
        "description" ->
            { page
                | fields = Dict.insert "description" val page.fields
                , deltas =
                    HabitStore.buildFieldChanges
                        page.deltas
                        (HabitStore.DescriptionChange val)
            }

        "tag" ->
            { page
                | fields = Dict.insert "tag" val page.fields
                , deltas =
                    HabitStore.buildFieldChanges
                        page.deltas
                        (HabitStore.TagChange val)
            }

        "period" ->
            { page
                | fields = Dict.insert "period" val page.fields
                , deltas =
                    HabitStore.buildFieldChanges
                        page.deltas
                        (HabitStore.PeriodChange (Period.parse val))
            }

        _ ->
            page


afterModalModelUpdate : Modal -> Model -> Model
afterModalModelUpdate modal model =
    case ( model.screen, modal ) of
        ( NoScreen, IntroModal ) ->
            { model | screen = HabitList { page = 0 } } |> slideFromTopTransition NoScreen

        ( _, _ ) ->
            model


afterTransitionModalUpdate : ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
afterTransitionModalUpdate ( model, cmd ) =
    let
        options =
            model.options
    in
    case model.screen of
        HabitList _ ->
            if not (List.member FirstHabitModal options.seenModals) then
                ( { model | modal = FirstHabitModal, options = { options | seenModals = FirstHabitModal :: options.seenModals } } |> modalInTransition, cmd ) |> storeModel

            else if not (List.member DoHabitModal options.seenModals) && not (Dict.isEmpty model.habits) then
                ( { model | modal = DoHabitModal, options = { options | seenModals = DoHabitModal :: options.seenModals } } |> modalInTransition, cmd ) |> storeModel

            else
                ( model, cmd )

        CreateHabit _ ->
            if not (List.member AddingHabitModal options.seenModals) then
                ( { model | modal = AddingHabitModal, options = { options | seenModals = AddingHabitModal :: options.seenModals } } |> modalInTransition, cmd ) |> storeModel

            else
                ( model, cmd )

        _ ->
            ( model, cmd )


afterDoHabitModalUpdate : Model -> Model
afterDoHabitModalUpdate model =
    let
        options =
            model.options
    in
    if not (List.member OpenOptionsModal options.seenModals) then
        { model | modal = OpenOptionsModal, options = { options | seenModals = OpenOptionsModal :: options.seenModals } } |> modalInTransition

    else
        model



-- VIEW


animationAttribs : Model -> String -> List (Html.Attribute Msg)
animationAttribs model key =
    Dict.get key model.animations
        |> Maybe.map Animation.render
        |> Maybe.withDefault []


view : Model -> Html Msg
view model =
    div
        []
        [ div
            [ class "page-container", id "habits-view" ]
            [ div
                (animationAttribs model "modal-bg")
                [ maybeViewTransition model ]
            ]
        , if model.modal /= NoModal then
            div
                (onClick CloseModal
                    :: class "modal"
                    :: animationAttribs model
                        "modal-fg"
                )
                [ viewModal model ]

          else
            div [] []
        ]


maybeViewTransition : Model -> Html Msg
maybeViewTransition model =
    case model.screenTransition of
        Nothing ->
            div
                [ class "static-page" ]
                [ viewScreen model ]

        Just (ScreenTransition transition) ->
            case transition.direction of
                TransitionIn ->
                    viewScreenTransition model model transition

                TransitionOut ->
                    viewScreenTransition model transition model


viewScreenTransition : Model -> ScreenModel a -> ScreenModel b -> Html Msg
viewScreenTransition model top bottom =
    div
        []
        [ div
            [ class "static-page" ]
            [ viewScreen bottom ]
        , div
            (class "transition-page"
                :: animationAttribs model "page-transition"
            )
            [ viewScreen top ]
        ]


viewScreen : ScreenModel a -> Html Msg
viewScreen model =
    case model.screen of
        HabitList habitList ->
            viewHabitsListPage model habitList

        EditHabit editPage ->
            viewEditingPage model editPage

        CreateHabit newPage ->
            viewNewPage model newPage

        EditOptions optionsPage ->
            viewOptionsPage model optionsPage

        SelectHabit habitSelect ->
            viewHabitSelectPage model habitSelect

        NoScreen ->
            div [ class "notvisible" ] [ viewEmptyPage model ]



-- HABITS VIEW


emptyDiv : Html msg
emptyDiv =
    div [] []


pageLines : Int
pageLines =
    18


viewEmptyPage : ScreenModel a -> Html Msg
viewEmptyPage _ =
    let
        pageConfig =
            { showOptions = False
            , title = ""
            , footer = ( emptyDiv, emptyDiv )
            , nLines = pageLines
            , pageMsg = PageAction
            }
    in
    viewPage pageConfig { pageNumber = 0 } []


habitOrderer : ScreenModel a -> Habit -> Int
habitOrderer model habit =
    if shouldBeMarkedAsDone model habit then
        Maybe.withDefault model.time habit.lastDone
            |> Time.posixToMillis

    else
        -1 * (Time.posixToMillis habit.nextDue - Time.posixToMillis model.time)


visibleHabits : ScreenModel a -> Dict HabitId Habit
visibleHabits model =
    Dict.filter (\_ v -> viewHabitFilter model v) model.habits


viewHabitsListPage : ScreenModel a -> HabitListScreen -> Html Msg
viewHabitsListPage model habitListScreen =
    let
        pageConfig =
            { showOptions = True
            , title = "today I will"
            , footer =
                ( button
                    [ class "add-habit", onClick OpenHabitCreate ]
                    [ text "+" ]
                , emptyDiv
                )
            , nLines = pageLines
            , pageMsg = PageAction
            }

        pageState =
            { pageNumber = habitListScreen.page }

        lines =
            visibleHabits model
                |> Dict.values
                |> List.sortBy (habitOrderer model)
                |> List.map (habitViewLine model)
    in
    viewPage pageConfig pageState lines


habitViewLine : ScreenModel a -> Habit -> PageLine Msg
habitViewLine model habit =
    ( button
        [ class "habit-edit"
        , onClick (OpenHabitEdit habit.id)
        ]
        [ text "..." ]
    , button
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


viewEditingPage : ScreenModel a -> EditHabitScreen -> Html Msg
viewEditingPage model screen =
    let
        title =
            Dict.get "description" screen.fields
                |> Maybe.withDefault ""

        pageConfig =
            { showOptions = False
            , title = "edit \"" ++ title ++ "\""
            , footer =
                ( emptyDiv
                , div
                    [ class "button-line" ]
                    [ button [ onClick DoEditHabit ] [ text "Save" ]
                    , button [ onClick DoDeleteHabit ] [ text "Delete" ]
                    , button [ onClick Cancel ] [ text "Cancel" ]
                    ]
                )
            , nLines = pageLines
            , pageMsg = PageAction
            }

        pageState =
            { pageNumber = 0 }

        lines =
            editPagelines model screen
    in
    viewPage pageConfig pageState lines


editPagelines : ScreenModel a -> EditHabitScreen -> PageLines Msg
editPagelines model screen =
    habitFieldsView screen.fields (Dict.values model.habits) (Just screen.habitId)



-- NEW VIEW


viewNewPage : ScreenModel a -> CreateHabitScreen -> Html Msg
viewNewPage model screen =
    let
        pageConfig =
            { showOptions = False
            , title = "new habit"
            , footer =
                ( emptyDiv
                , div
                    [ class "button-line" ]
                    [ button [ onClick (DoCreateHabit Nothing) ] [ text "Create" ]
                    , button [ onClick Cancel ] [ text "Cancel" ]
                    ]
                )
            , nLines = pageLines
            , pageMsg = PageAction
            }

        pageState =
            { pageNumber = 0 }

        lines =
            createPagelines model screen
    in
    viewPage pageConfig pageState lines


createPagelines : ScreenModel a -> CreateHabitScreen -> PageLines Msg
createPagelines model screen =
    habitFieldsView screen.fields (Dict.values model.habits) Nothing


getWithDefault : FormFields -> String -> String -> String
getWithDefault dict default key =
    Dict.get key dict |> Maybe.withDefault default


habitFieldsView :
    FormFields
    -> List Habit
    -> Maybe HabitId
    -> PageLines Msg
habitFieldsView fields habits maybeHabit =
    let
        tagOption tag =
            option [ value tag ] [ text tag ]

        tagOptions =
            List.map .tag habits
                |> Set.fromList
                |> Set.toList
                |> List.map tagOption

        fieldGetter =
            getWithDefault fields ""

        -- TODO this should only change on blur of description field
        -- Should not be clickable if not filled out
        blockText =
            case Dict.get "block" fields of
                Nothing ->
                    "last time"

                Just hid ->
                    List.filter (\h -> h.id == hid) habits
                        |> List.head
                        |> Maybe.map .description
                        |> Maybe.withDefault "last time"
    in
    [ ( emptyDiv, label [] [ text "I want to" ] )
    , ( emptyDiv
      , input
            [ placeholder "Do Something"
            , value (fieldGetter "description")
            , onInput (ChangeFormField "description")
            ]
            []
      )
    , ( emptyDiv, label [] [ text "every" ] )
    , ( periodOptionsView (fieldGetter "period") "period-list"
      , input
            -- TODO Select entire description when clicked
            [ placeholder "Day"
            , value (fieldGetter "period")
            , list "period-list"
            , onInput (ChangeFormField "period")
            ]
            []
      )
    , ( emptyDiv, label [] [ text "after" ] )
    , ( emptyDiv
      , button
            [ class "habit-button-select"
            , onClick
                (OpenHabitSelect { id = maybeHabit, description = fieldGetter "description" }
                    (Dict.get "block" fields)
                )
            ]
            [ text blockText ]
      )
    , ( emptyDiv, label [] [ text "category" ] )
    , ( datalist
            [ id "tag-list" ]
            tagOptions
      , input
            [ placeholder "Todo"
            , value (fieldGetter "tag")
            , list "tag-list"
            , onInput (ChangeFormField "tag")
            ]
            []
      )
    ]



-- OPTIONS VIEW


viewOptionsPage : ScreenModel a -> EditOptionsScreen -> Html Msg
viewOptionsPage model screen =
    let
        pageConfig =
            { showOptions = False
            , title = "View Options"
            , footer =
                ( emptyDiv
                , emptyDiv
                )
            , nLines = pageLines
            , pageMsg = PageAction
            }

        pageState =
            { pageNumber = 0 }

        seenAllHelp =
            List.length model.options.seenModals == 5

        lines =
            [ ( emptyDiv, label [] [ text "Show upcoming" ] )
            , ( periodOptionsView screen.upcoming "upcoming-list"
              , input
                    [ value screen.upcoming, list "upcoming-list", onInput (ChangeFormField "upcoming") ]
                    []
              )
            , ( emptyDiv, label [] [ text "Show recently done" ] )
            , ( periodOptionsView screen.recent "recent-list"
              , input
                    [ value screen.recent, list "recent-list", onInput (ChangeFormField "recent") ]
                    []
              )
            , ( emptyDiv
              , div
                    [ class "button-line" ]
                    [ button [ onClick DoSaveOptions ] [ text "Save" ]
                    , button [ onClick Cancel ] [ text "Cancel" ]
                    ]
              )
            , ( emptyDiv, emptyDiv )
            , ( emptyDiv, emptyDiv )
            , ( emptyDiv
              , div
                    [ class "button-line" ]
                    [ button [ onClick DoToggleHelp ]
                        [ text
                            (if seenAllHelp then
                                "Show Help"

                             else
                                "Hide Help"
                            )
                        ]
                    ]
              )
            , ( emptyDiv, emptyDiv )
            , ( emptyDiv, emptyDiv )
            , ( emptyDiv
              , div
                    [ class "button-line" ]
                    [ button [ onClick DoClearData ] [ text "Clear Habits" ]
                    ]
              )
            ]
    in
    viewPage pageConfig pageState lines



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


viewHabitSelectPage : ScreenModel a -> SelectHabitScreen -> Html Msg
viewHabitSelectPage model screen =
    let
        pageConfig =
            { showOptions = False
            , title = "\"" ++ screen.forHabit.description ++ "\" after"
            , footer =
                ( emptyDiv
                , div
                    [ class "button-line" ]
                    [ button [ onClick Cancel ] [ text "Cancel" ]
                    ]
                )
            , nLines = pageLines
            , pageMsg = PageAction
            }

        pageState =
            { pageNumber = screen.page }

        { habits } =
            model

        lines =
            habitSelectLine screen.selected { id = Nothing, description = "last time" }
                :: (Dict.filter (\k _ -> Maybe.map ((/=) k) screen.forHabit.id |> Maybe.withDefault True) habits
                        |> Dict.values
                        |> List.sortBy .description
                        |> List.map (\h -> { id = Just h.id, description = h.description })
                        |> List.map (habitSelectLine screen.selected)
                   )
    in
    viewPage pageConfig pageState lines


habitSelectLine : Maybe HabitId -> PartialHabit -> PageLine Msg
habitSelectLine selected habit =
    ( emptyDiv
    , button
        [ class "habit-button"
        , onClick (DoSelectHabit habit.id)
        ]
        [ span
            [ class "habit-description"
            , if habit.id == selected then
                class "selected"

              else
                class "not-selected"
            ]
            [ text habit.description ]
        ]
    )



-- Help Modals


viewModal : Model -> Html Msg
viewModal model =
    case model.modal of
        NoModal ->
            div [] []

        IntroModal ->
            div
                [ class "intro-modal" ]
                [ p [] [ text "habits is a way to keep track of repeating tasks." ]
                , p [] [ text "It's like a todo list where things show up again a certain amount of time after you do them." ]
                ]

        FirstHabitModal ->
            div
                [ class "intro-modal" ]
                [ p [] [ text "This is your due list, it's looking a little bare." ]
                , p [] [ text "Add a habit with the + button." ]
                ]

        AddingHabitModal ->
            div
                [ class "intro-modal" ]
                [ p [] [ text "A habit needs a name and a repeat period." ]
                , p [] [ text "You can make the habit due after the last time you did it or after doing a different habit." ]
                ]

        DoHabitModal ->
            div
                [ class "intro-modal" ]
                [ p [] [ text "That's looking better!" ]
                , p [] [ text "Clicking a habit marks it as done, you can also edit habits by clicking the ..." ]
                ]

        OpenOptionsModal ->
            div
                [ class "intro-modal" ]
                [ p [] [ text "🎉🎉🎉" ]
                , p [] [ text "By defualt your list shows habits due within the next 12 hours or done within the last 12 hours." ]
                , p [] [ text "You can access the view options by clicking the - button to change this." ]
                ]



-- Due Helpers
-- TODO move some of these into habit


isDueSoon : ScreenModel a -> Habit -> Bool
isDueSoon { time, options } habit =
    Habit.isDue (addToPosix options.upcoming time) habit


isRecentlyDone : ScreenModel a -> Habit -> Bool
isRecentlyDone { time, options } habit =
    habit.lastDone
        |> Maybe.map (\l -> posixToMillis l > posixToMillis (minusFromPosix options.recent time))
        |> Maybe.withDefault False


shouldBeMarkedAsDone : ScreenModel a -> Habit -> Bool
shouldBeMarkedAsDone model habit =
    if Habit.isBlocked habit then
        True

    else if Period.toMillis habit.period > Period.toMillis model.options.upcoming then
        not (isDueSoon model habit)

    else
        not (Habit.isDue model.time habit)


viewHabitFilter : ScreenModel a -> Habit -> Bool
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



-- Encode/Decode


defaultStorageModel : StorageModel
defaultStorageModel =
    StorageModel defaultOptions [] 0


storageDecoder : JD.Decoder StorageModel
storageDecoder =
    JD.map3 StorageModel
        (JD.field "options" optionsDecoder)
        (JD.field "habits" (JD.list HabitStore.decoder))
        (JD.succeed 0)


storageEncoder : Model -> JE.Value
storageEncoder model =
    JE.object
        [ ( "options", optionsEncoder model.options )
        , ( "habits", JE.list HabitStore.encode (HabitStore.deltasFromDict model.time model.habits) )
        , ( "version", JE.int 0 )
        ]


optionsDecoder : JD.Decoder Options
optionsDecoder =
    JD.map3 Options
        (JD.field "recent" Period.decoder)
        (JD.field "upcoming" Period.decoder)
        (JD.field "seenModals" (JD.list modalDecoder))


optionsEncoder : Options -> JE.Value
optionsEncoder options =
    JE.object
        [ ( "recent", Period.encode options.recent )
        , ( "upcoming", Period.encode options.upcoming )
        , ( "seenModals", JE.list modalEncoder options.seenModals )
        ]


modalEncoder : Modal -> JE.Value
modalEncoder modal =
    case modal of
        NoModal ->
            JE.int 0

        IntroModal ->
            JE.int 1

        FirstHabitModal ->
            JE.int 2

        AddingHabitModal ->
            JE.int 3

        DoHabitModal ->
            JE.int 4

        OpenOptionsModal ->
            JE.int 5


modalDecoder : JD.Decoder Modal
modalDecoder =
    JD.int
        |> JD.andThen
            (\field ->
                case field of
                    1 ->
                        JD.succeed IntroModal

                    2 ->
                        JD.succeed FirstHabitModal

                    3 ->
                        JD.succeed AddingHabitModal

                    4 ->
                        JD.succeed DoHabitModal

                    5 ->
                        JD.succeed OpenOptionsModal

                    _ ->
                        JD.succeed NoModal
            )



-- Transition appliers
{-
   Type of transitions

         slideFromTop (old one static, new one slide in)
              New Habit
         slideOffbottom (old one slide out, new one static)
              Delete habit
         flipOffRight (old one slide off - need z index, new one static)
              Prev Page Page, save (all of them), Select habit
         flipOffLeft (old one slide off - need z index, new one static)
              Cancel (all of them)
         flipOn (old one static, new one slide in - need z index)
              Next Page
-}


slideEase =
    Animation.easing
        { duration = 400
        , ease = Ease.inOutCubic
        }


slideEase2 =
    Animation.easing
        { duration = 700
        , ease = Ease.inOutCubic
        }


modalInTransition : Model -> Model
modalInTransition model =
    { model
        | animations =
            Dict.update "modal-fg"
                (\m ->
                    Just
                        (Animation.interrupt
                            [ Animation.toWith slideEase2 [ Animation.opacity 1 ]
                            ]
                            (Maybe.withDefault
                                (Animation.style [ Animation.opacity 0 ])
                                m
                            )
                        )
                )
                model.animations
    }


modalOutTransition : Model -> Model
modalOutTransition model =
    { model
        | animations =
            Dict.update "modal-fg"
                (\m ->
                    Just
                        (Animation.interrupt
                            [ Animation.toWith slideEase2 [ Animation.opacity 0 ]
                            , Animation.Messenger.send ClearModal
                            ]
                            (Maybe.withDefault
                                (Animation.style [ Animation.opacity 1 ])
                                m
                            )
                        )
                )
                model.animations
    }


fadeTransition : Model -> Model
fadeTransition model =
    let
        { habits, time, screen, options } =
            model
    in
    { model
        | screenTransition =
            Just
                (ScreenTransition
                    { habits = habits
                    , time = time
                    , screen = screen
                    , options = options
                    , direction = TransitionIn
                    }
                )
        , screen = model.screen
        , animations =
            Dict.insert "page-transition"
                (Animation.interrupt
                    [ Animation.to [ Animation.opacity 1 ]
                    , Animation.Messenger.send ClearTransition
                    ]
                    (Animation.style
                        [ Animation.opacity 0, Animation.top (Animation.px 0) ]
                    )
                )
                model.animations
    }


slideFromTopTransition : Screen -> Model -> Model
slideFromTopTransition newScreen model =
    let
        { habits, time, screen, options } =
            model
    in
    case model.pageElement of
        Nothing ->
            model

        Just el ->
            let
                top =
                    -1 * (el.element.y + el.element.height)
            in
            { model
                | screenTransition =
                    Just
                        (ScreenTransition
                            { habits = habits
                            , time = time
                            , screen = screen
                            , options = options
                            , direction = TransitionIn
                            }
                        )
                , screen = newScreen
                , animations =
                    Dict.insert "page-transition"
                        (Animation.interrupt
                            [ Animation.toWith slideEase [ Animation.top (Animation.px 0) ]
                            , Animation.Messenger.send ClearTransition
                            ]
                            (Animation.style
                                [ Animation.top (Animation.px top)
                                ]
                            )
                        )
                        model.animations
            }


slideOffbottom : Screen -> Model -> Model
slideOffbottom newScreen model =
    let
        { habits, time, screen, options } =
            model
    in
    case model.pageElement of
        Nothing ->
            model

        Just el ->
            let
                top =
                    el.viewport.height + (el.element.y * 2)
            in
            { model
                | screenTransition =
                    Just
                        (ScreenTransition
                            { habits = habits
                            , time = time
                            , screen = screen
                            , options = options
                            , direction = TransitionOut
                            }
                        )
                , screen = newScreen
                , animations =
                    Dict.insert "page-transition"
                        (Animation.interrupt
                            [ Animation.toWith slideEase [ Animation.top (Animation.px top) ]
                            , Animation.Messenger.send ClearTransition
                            ]
                            (Animation.style
                                [ Animation.top (Animation.px 0)
                                ]
                            )
                        )
                        model.animations
            }


flipOffRight : Screen -> Model -> Model
flipOffRight newScreen model =
    let
        { habits, time, screen, options } =
            model
    in
    case model.pageElement of
        Nothing ->
            model

        Just el ->
            let
                left =
                    el.element.width
            in
            { model
                | screenTransition =
                    Just
                        (ScreenTransition
                            { habits = habits
                            , time = time
                            , screen = screen
                            , options = options
                            , direction = TransitionOut
                            }
                        )
                , screen = newScreen
                , animations =
                    Dict.insert "page-transition"
                        (Animation.interrupt
                            [ Animation.toWith
                                slideEase
                                [ Animation.left (Animation.px left) ]
                            , Animation.set [ Animation.exactly "z-index" "1" ]
                            , Animation.toWith
                                slideEase
                                [ Animation.left (Animation.px 0) ]
                            , Animation.Messenger.send ClearTransition
                            ]
                            (Animation.style
                                [ Animation.top (Animation.px 0)
                                , Animation.left (Animation.px 0)
                                , Animation.exactly "z-index" "2"
                                ]
                            )
                        )
                        model.animations
            }


flipOn : Screen -> Model -> Model
flipOn newScreen model =
    let
        { habits, time, screen, options } =
            model
    in
    case model.pageElement of
        Nothing ->
            model

        Just el ->
            let
                right =
                    el.element.width
            in
            { model
                | screenTransition =
                    Just
                        (ScreenTransition
                            { habits = habits
                            , time = time
                            , screen = screen
                            , options = options
                            , direction = TransitionIn
                            }
                        )
                , screen = newScreen
                , animations =
                    Dict.insert "page-transition"
                        (Animation.interrupt
                            [ Animation.toWith slideEase [ Animation.right (Animation.px right) ]
                            , Animation.set [ Animation.exactly "z-index" "2" ]
                            , Animation.toWith slideEase [ Animation.right (Animation.px 0) ]
                            , Animation.Messenger.send ClearTransition
                            ]
                            (Animation.style
                                [ Animation.top (Animation.px 0)
                                , Animation.right (Animation.px 0)
                                , Animation.exactly "z-index" "1"
                                ]
                            )
                        )
                        model.animations
            }
