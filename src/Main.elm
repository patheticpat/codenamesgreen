module Main exposing (Model, Msg(..), init, main, update, view)

import Api
import Browser
import Browser.Navigation as Nav
import Dict
import Game
import Html exposing (Html, a, button, div, form, h1, h2, h3, i, input, p, span, strong, text)
import Html.Attributes as Attr
import Html.Events exposing (onClick, onInput, onSubmit)
import Html.Lazy exposing (lazy, lazy2, lazy3)
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
    , user : User.User
    , page : Page
    , apiClient : Api.Client
    }


type Page
    = NotFound
    | Error String
    | Home String
    | GameLoading String
    | GameInProgress Game.Model String GameView


type GameView
    = ShowDefault
    | ShowSettings


init : Json.Decode.Value -> Url.Url -> Nav.Key -> ( Model, Cmd Msg )
init encodedUser url key =
    case User.decode encodedUser of
        Err e ->
            ( { key = key
              , user = User.User "" ""
              , page = Error (Json.Decode.errorToString e)
              , apiClient = Api.init url
              }
            , Cmd.none
            )

        Ok user ->
            stepUrl url
                { key = key
                , user = user
                , page = Home ""
                , apiClient = Api.init url
                }



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
    | GotGame (Result Http.Error Api.GameState)
    | ChatMessageChanged String
    | SendChat
    | ToggleSettings GameView


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case ( msg, model.page ) of
        ( LinkClicked urlRequest, _ ) ->
            case urlRequest of
                Browser.Internal url ->
                    ( model
                    , Nav.pushUrl model.key (Url.toString url)
                    )

                Browser.External href ->
                    ( model
                    , Nav.load href
                    )

        ( UrlChanged url, _ ) ->
            stepUrl url model

        ( IdChanged id, Home _ ) ->
            ( { model | page = Home id }, Cmd.none )

        ( SubmitNewGame, Home id ) ->
            ( model, Nav.pushUrl model.key (UrlBuilder.relative [ id ] []) )

        ( NextGame, GameInProgress game _ _ ) ->
            stepGameView model game.id (Just game.seed)

        ( GameUpdate gameMsg, GameInProgress game chat gameView ) ->
            let
                ( newGame, gameCmd ) =
                    Game.update gameMsg game
            in
            ( { model | page = GameInProgress newGame chat gameView }, Cmd.map GameUpdate gameCmd )

        ( GotGame (Ok state), GameInProgress old chat _ ) ->
            let
                ( gameModel, gameCmd ) =
                    Game.init state model.user model.apiClient
            in
            ( { model | page = GameInProgress gameModel chat ShowDefault }, Cmd.map GameUpdate gameCmd )

        ( GotGame (Ok state), GameLoading id ) ->
            let
                ( gameModel, gameCmd ) =
                    Game.init state model.user model.apiClient
            in
            ( { model | page = GameInProgress gameModel "" ShowDefault }, Cmd.map GameUpdate gameCmd )

        ( PickSide side, GameInProgress oldGame chat gameView ) ->
            let
                oldPlayer =
                    oldGame.player

                game =
                    { oldGame | player = { oldPlayer | side = Just side } }
            in
            ( { model | page = GameInProgress game chat gameView }
            , Api.ping
                -- Pinging will immediately record the change on the
                -- serverside, without having to wait for the long
                -- poll to make a new request.
                { gameId = game.id
                , player = game.player
                , toMsg = always NoOp
                , client = model.apiClient
                }
            )

        ( ChatMessageChanged message, GameInProgress g _ gameView ) ->
            ( { model | page = GameInProgress g message gameView }, Cmd.none )

        ( SendChat, GameInProgress g message gameView ) ->
            ( { model | page = GameInProgress g "" gameView }
            , Api.chat
                { gameId = g.id
                , player = g.player
                , toMsg = always NoOp
                , message = message
                , client = model.apiClient
                }
            )

        ( ToggleSettings gameView, GameInProgress g message _ ) ->
            ( { model | page = GameInProgress g message gameView }, Cmd.none )

        ( GotGame (Err e), _ ) ->
            -- TODO: display an error message
            ( model, Cmd.none )

        _ ->
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
    ( { model | page = GameLoading id }
    , Api.maybeMakeGame
        { gameId = id
        , prevSeed = prevSeed
        , toMsg = GotGame
        , client = model.apiClient
        }
    )


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

        GameInProgress game chat gameView ->
            viewGameInProgress game chat gameView

        Error msg ->
            viewError msg


viewNotFound : Browser.Document Msg
viewNotFound =
    div [ Attr.id "not-found" ]
        [ h2 [] [ text "Page not found" ]
        , p []
            [ text "That page doesn't exist. "
            , a [ Attr.href "/" ] [ text "Go to the homepage" ]
            ]
        ]
        |> viewLayout (Just "Page not found")


viewLayout : Maybe String -> Html Msg -> Browser.Document Msg
viewLayout subtitle content =
    { title =
        case subtitle of
            Just t ->
                "Codenames Green | " ++ t

            Nothing ->
                "Codenames Green"
    , body =
        [ div [ Attr.id "layout" ]
            [ viewHeader
            , div [ Attr.id "content" ] [ content ]
            ]
        ]
    }


viewError : String -> Browser.Document Msg
viewError msg =
    div [ Attr.id "error" ]
        [ h2 [] [ text "Oops" ]
        , p []
            [ text "An unexpected error was encountered. Most likely this is the result of corrupted local storage. Try clearing all storage associated with the app." ]
        , p [] [ strong [] [ text "Error: " ], text msg ]
        ]
        |> viewLayout (Just "Error")


viewGameInProgress : Game.Model -> String -> GameView -> Browser.Document Msg
viewGameInProgress g chatMessage gameView =
    div [ Attr.id "game" ]
        [ Html.map GameUpdate (Game.viewBoard g)
        , div [ Attr.id "sidebar" ] (viewSidebar g chatMessage gameView)
        ]
        |> viewLayout Nothing


viewSidebar : Game.Model -> String -> GameView -> List (Html Msg)
viewSidebar g chatMessage gameView =
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
    case ( g.player.side, gameView ) of
        ( Nothing, _ ) ->
            [ viewJoinASide playersOnSideA playersOnSideB ]

        ( _, ShowSettings ) ->
            viewSettings g

        ( Just side, ShowDefault ) ->
            viewActiveSidebar g side chatMessage


viewSettings : Game.Model -> List (Html Msg)
viewSettings g =
    [ div [ Attr.id "settings" ]
        [ div []
            [ i
                [ Attr.class "icon ion-ios-arrow-back icon-button back-button"
                , onClick (ToggleSettings ShowDefault)
                ]
                []
            ]
        ]
    ]


viewActiveSidebar : Game.Model -> Side.Side -> String -> List (Html Msg)
viewActiveSidebar g side chatMessage =
    [ lazy Game.viewStatus g
    , Html.map GameUpdate (lazy2 Game.viewKeycard g side)
    , lazy3 viewEventBox g side chatMessage
    , viewButtonRow
    ]


viewEventBox : Game.Model -> Side.Side -> String -> Html Msg
viewEventBox g side chatMessage =
    div [ Attr.id "event-log" ]
        [ Html.map GameUpdate (Game.viewEvents g)
        , form [ Attr.id "chat-form", onSubmit SendChat ]
            [ input [ Attr.value chatMessage, onInput ChatMessageChanged ] []
            , button [] [ text "Send" ]
            ]
        ]


viewButtonRow : Html Msg
viewButtonRow =
    div [ Attr.id "button-row" ]
        [ div [] [ button [ onClick NextGame ] [ text "Next game" ] ]
        , div [] [ i [ Attr.id "open-settings", Attr.class "icon icon-button ion-ios-settings", onClick (ToggleSettings ShowSettings) ] [] ]
        ]


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
