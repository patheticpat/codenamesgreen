module Main exposing (Model, Msg(..), init, main, update, view)

import Browser
import Browser.Navigation as Nav
import Dict
import Game
import Html exposing (Html, a, button, div, form, h1, h2, h3, img, input, p, span, strong, text)
import Html.Attributes as Attr
import Html.Events exposing (onClick, onInput, onSubmit)
import Html.Lazy exposing (lazy, lazy2)
import Http
import Json.Decode
import Loading exposing (LoaderType(..), defaultConfig)
import Side
import Url
import Url.Builder as UrlBuilder
import Url.Parser as Parser exposing ((</>), Parser, map, oneOf, string, top)
import Url.Parser.Query as Query
import User



---- MODEL ----


type alias Model =
    { key : Nav.Key
    , playerId : String
    , page : Page
    , apiUrl : String
    }


type Page
    = NotFound
    | Error String
    | Home String
    | GameLoading String
    | GameInProgress Game.Model


init : Json.Decode.Value -> Url.Url -> Nav.Key -> ( Model, Cmd Msg )
init encodedUser url key =
    case User.decode encodedUser of
        Err e ->
            ( { key = key, playerId = "", page = Error (Json.Decode.errorToString e), apiUrl = apiUrl url }, Cmd.none )

        Ok user ->
            stepUrl url { key = key, playerId = user.playerId, page = Home "", apiUrl = apiUrl url }


apiUrl : Url.Url -> String
apiUrl url =
    case url.host of
        "localhost" ->
            Url.toString { url | port_ = Just 8080, path = "", query = Nothing, fragment = Nothing }

        "www.codenamesgreen.com" ->
            Url.toString { url | host = "api.codenamesgreen.com", path = "", query = Nothing, fragment = Nothing }

        _ ->
            Url.toString { url | host = "api." ++ url.host, path = "", query = Nothing, fragment = Nothing }



---- UPDATE ----


type Msg
    = NoOp
    | LinkClicked Browser.UrlRequest
    | UrlChanged Url.Url
    | IdChanged String
    | SubmitNewGame
    | NextGame
    | PickSide Side.Side
    | GameUpdate Game.Msg
    | GotGame (Result Http.Error Game.GameData)


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        LinkClicked urlRequest ->
            case urlRequest of
                Browser.Internal url ->
                    ( model
                    , Nav.pushUrl model.key (Url.toString url)
                    )

                Browser.External href ->
                    ( model
                    , Nav.load href
                    )

        UrlChanged url ->
            stepUrl url model

        IdChanged id ->
            case model.page of
                Home _ ->
                    ( { model | page = Home id }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        SubmitNewGame ->
            case model.page of
                Home id ->
                    ( model, Nav.pushUrl model.key (UrlBuilder.relative [ id ] []) )

                _ ->
                    ( model, Cmd.none )

        NextGame ->
            case model.page of
                GameInProgress game ->
                    stepGameView model game.id (Just game.seed)

                _ ->
                    ( model, Cmd.none )

        GameUpdate gameMsg ->
            case model.page of
                GameInProgress game ->
                    let
                        ( newGame, gameCmd ) =
                            Game.update gameMsg game
                    in
                    ( { model | page = GameInProgress newGame }, Cmd.map GameUpdate gameCmd )

                _ ->
                    ( model, Cmd.none )

        GotGame (Ok data) ->
            case model.page of
                GameInProgress old ->
                    let
                        ( gameModel, gameCmd ) =
                            Game.init old.id data model.playerId model.apiUrl
                    in
                    ( { model | page = GameInProgress gameModel }, Cmd.map GameUpdate gameCmd )

                GameLoading id ->
                    let
                        ( gameModel, gameCmd ) =
                            Game.init id data model.playerId model.apiUrl
                    in
                    ( { model | page = GameInProgress gameModel }, Cmd.map GameUpdate gameCmd )

                _ ->
                    ( model, Cmd.none )

        PickSide side ->
            case model.page of
                GameInProgress game ->
                    let
                        old =
                            game.player
                    in
                    ( { model | page = GameInProgress { game | player = { old | side = Just side } } }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        -- TODO: display an error message
        GotGame (Err e) ->
            ( model, Cmd.none )

        NoOp ->
            ( model, Cmd.none )


stepUrl : Url.Url -> Model -> ( Model, Cmd Msg )
stepUrl url model =
    case Maybe.withDefault NullRoute (Parser.parse route url) of
        NullRoute ->
            ( { model | page = NotFound }, Cmd.none )

        Index ->
            ( { model | page = Home "" }, Cmd.none )

        GameView id ->
            stepGameView model id Nothing


stepGameView : Model -> String -> Maybe String -> ( Model, Cmd Msg )
stepGameView model id prevSeed =
    ( { model | page = GameLoading id }, Game.maybeMakeGame model.apiUrl id prevSeed GotGame )


type Route
    = NullRoute
    | Index
    | GameView String


route : Parser (Route -> a) a
route =
    oneOf
        [ map Index top
        , map GameView string
        ]



---- VIEW ----


view : Model -> Browser.Document Msg
view model =
    case model.page of
        NotFound ->
            viewNotFound

        Home id ->
            viewHome id

        GameLoading id ->
            { title = "Codenames Green"
            , body = viewGameLoading id
            }

        GameInProgress game ->
            viewGameInProgress game

        Error msg ->
            viewError msg


viewNotFound : Browser.Document Msg
viewNotFound =
    { title = "Codenames Green | Page not found"
    , body =
        [ viewHeader
        , div [ Attr.id "not-found" ]
            [ h2 [] [ text "Page not found" ]
            , p []
                [ text "That page doesn't exist. "
                , a [ Attr.href "/" ] [ text "Go to the homepage" ]
                ]
            ]
        ]
    }


viewError : String -> Browser.Document Msg
viewError msg =
    { title = "Codenames Green | Page not found"
    , body =
        [ viewHeader
        , div [ Attr.id "error" ]
            [ h2 [] [ text "Oops" ]
            , p []
                [ text "An unexpected error was encountered. Most likely this is the result of corrupted local storage. Try clearing all storage associated with the app." ]
            , p [] [ strong [] [ text "Error: " ], text msg ]
            ]
        ]
    }


viewGameInProgress : Game.Model -> Browser.Document Msg
viewGameInProgress g =
    { title = "Codenames Green"
    , body =
        [ viewHeader
        , div [ Attr.id "game" ]
            [ Html.map GameUpdate (Game.viewBoard g)
            , div [ Attr.id "sidebar" ] (viewSidebar g)
            ]
        ]
    }


viewSidebar : Game.Model -> List (Html Msg)
viewSidebar g =
    let
        sides =
            Dict.values g.players

        playersOnSideA =
            sides
                |> List.filter (\x -> x == Side.A)
                |> List.length

        playersOnSideB =
            sides
                |> List.filter (\x -> x == Side.B)
                |> List.length
    in
    case g.player.side of
        Nothing ->
            [ viewJoinASide playersOnSideA playersOnSideB ]

        Just side ->
            viewActiveSidebar g side


viewActiveSidebar : Game.Model -> Side.Side -> List (Html Msg)
viewActiveSidebar g side =
    [ lazy Game.viewStatus g
    , lazy2 Game.viewKeycard g side
    , Html.map GameUpdate (lazy Game.viewEventLog g)
    , viewNextGameButton
    ]


viewNextGameButton : Html Msg
viewNextGameButton =
    div [ Attr.id "next-game" ]
        [ button [ onClick NextGame ] [ text "Next game" ] ]


viewJoinASide : Int -> Int -> Html Msg
viewJoinASide a b =
    div [ Attr.id "join-a-team" ]
        [ h3 [] [ text "Pick a side" ]
        , p [] [ text "Pick a side to start playing. Each side has a different key card." ]
        , div [ Attr.class "buttons" ]
            [ button [ onClick (PickSide Side.A) ]
                [ span [ Attr.class "call-to-action" ] [ text "A" ]
                , span [ Attr.class "details" ] [ text "(", text (String.fromInt a), text " players)" ]
                ]
            , button [ onClick (PickSide Side.B) ]
                [ span [ Attr.class "call-to-action" ] [ text "B" ]
                , span [ Attr.class "details" ] [ text "(", text (String.fromInt b), text " players)" ]
                ]
            ]
        ]


viewGameLoading : String -> List (Html Msg)
viewGameLoading id =
    [ viewHeader
    , div [ Attr.id "game-loading" ]
        [ Loading.render Circle { defaultConfig | size = 100, color = "#b7ec8a" } Loading.On
        ]
    ]


viewHome : String -> Browser.Document Msg
viewHome id =
    { title = "Codenames Green"
    , body =
        [ div [ Attr.id "home" ]
            [ h1 [] [ text "Codenames Green" ]
            , p [] [ text "Play cooperative Codenames online across multiple devices on a shared board. To create a new game or join an existing game, enter a game identifier and click 'Play'." ]
            , form
                [ Attr.id "new-game"
                , onSubmit SubmitNewGame
                ]
                [ input
                    [ Attr.id "game-id"
                    , Attr.name "game-id"
                    , Attr.value id
                    , onInput IdChanged
                    ]
                    []
                , button [] [ text "Play" ]
                ]
            ]
        ]
    }


viewHeader : Html Msg
viewHeader =
    div [ Attr.id "header" ] [ a [ Attr.href "/" ] [ h1 [] [ text "Codenames Green" ] ] ]



---- PROGRAM ----


main : Program Json.Decode.Value Model Msg
main =
    Browser.application
        { view = view
        , init = init
        , update = update
        , subscriptions = always Sub.none
        , onUrlRequest = LinkClicked
        , onUrlChange = UrlChanged
        }
