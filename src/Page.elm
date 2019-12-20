module Page exposing (PageConfig, PageLine, PageLines, PageMessage(..), PageState, cullPageLines, viewEmptyLine, viewPage, viewPageFooter, viewPageLine, viewPageLines)

import Html exposing (..)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)


type PageMessage
    = ChangePage Int
    | OpenOptions


type alias PageConfig msg =
    { showOptions : Bool
    , title : String
    , footer : PageLine msg
    , nLines : Int
    , pageMsg : PageMessage -> msg
    }


type alias PageState =
    { pageNumber : Int
    }


type alias PageLine msg =
    ( Html msg, Html msg )


type alias PageLines msg =
    List (PageLine msg)


cullPageLines : PageConfig msg -> PageState -> PageLines msg -> PageLines msg
cullPageLines { nLines } { pageNumber } lines =
    lines
        |> List.drop (pageNumber * nLines)
        |> List.take nLines


viewPageLine : PageLine msg -> Html msg
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


viewEmptyLine : Html msg
viewEmptyLine =
    div
        [ class "page-line" ]
        [ div
            [ class "margin" ]
            []
        , div
            [ class "line-content" ]
            []
        ]


viewPageLines : PageLines msg -> PageLine msg -> Html msg
viewPageLines lines footer =
    div
        [ class "page-lines" ]
        (List.map viewPageLine
            (lines
                ++ [ footer ]
            )
        )


viewPageFooter : PageConfig msg -> PageState -> PageLines msg -> Html msg
viewPageFooter { nLines, pageMsg } { pageNumber } lines =
    div
        [ class "page-foot" ]
        [ div
            [ class "margin" ]
            (if pageNumber > 0 then
                [ button
                    [ class "add-habit", onClick (pageMsg (ChangePage (pageNumber - 1))) ]
                    [ text "<" ]
                ]

             else
                []
            )
        , div
            [ class "line-content" ]
            (if List.length lines > nLines then
                [ button
                    [ class "add-habit", onClick (pageMsg (ChangePage (pageNumber + 1))) ]
                    [ text ">" ]
                ]

             else
                []
            )
        ]


viewPage : PageConfig msg -> PageState -> PageLines msg -> Html msg
viewPage config state lines =
    let
        culledLines =
            cullPageLines config state lines

        nEmptyLines =
            config.nLines - List.length culledLines
    in
    div
        [ class "page" ]
        [ div
            [ class "page-head" ]
            [ div
                [ class "margin" ]
                (if config.showOptions then
                    [ button
                        [ class "add-habit", onClick (config.pageMsg OpenOptions) ]
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
        , div
            []
            (List.range 1 nEmptyLines |> List.map (\_ -> viewEmptyLine))
        , viewPageFooter config state lines
        ]
