module Pages.StaticHttpRequest exposing (Error(..), MockResolver, RawRequest(..), Status(..), cacheRequestResolution, mockResolve, toBuildError)

import BuildError exposing (BuildError)
import FatalError exposing (FatalError)
import Json.Encode
import Pages.Internal.FatalError
import Pages.StaticHttp.Request
import RequestsAndPending exposing (RequestsAndPending)
import TerminalText as Terminal


type alias MockResolver =
    Pages.StaticHttp.Request.Request
    -> Maybe RequestsAndPending.Response


type RawRequest error value
    = Request (List Pages.StaticHttp.Request.Request) (Maybe MockResolver -> RequestsAndPending -> RawRequest error value)
    | ApiRoute (Result error value)
    | InternalError FatalError


type Error
    = DecoderError String
    | UserCalledStaticHttpFail String
    | InternalFailure FatalError


toBuildError : String -> Error -> BuildError
toBuildError path error =
    case error of
        DecoderError decodeErrorMessage ->
            { title = "Static Http Decoding Error"
            , message =
                [ Terminal.text decodeErrorMessage
                ]
            , path = path
            , fatal = True
            }

        UserCalledStaticHttpFail decodeErrorMessage ->
            { title = "Called Static Http Fail"
            , message =
                [ Terminal.text <| "I ran into a call to `BackendTask.fail` with message: " ++ decodeErrorMessage
                ]
            , path = path
            , fatal = True
            }

        InternalFailure (Pages.Internal.FatalError.FatalError buildError) ->
            { title = "Internal error"
            , message =
                [ Terminal.text <| "Please report this error!"
                , Terminal.text ""
                , Terminal.text ""
                , Terminal.text buildError.body
                ]
            , path = path
            , fatal = True
            }


mockResolve : (FatalError -> error) -> RawRequest error value -> MockResolver -> Result error value
mockResolve onInternalError request mockResolver =
    case request of
        Request _ lookupFn ->
            let
                nextRequest : RawRequest error value
                nextRequest =
                    lookupFn (Just mockResolver) (Json.Encode.object [])
            in
            mockResolve onInternalError nextRequest mockResolver

        ApiRoute value ->
            value

        InternalError err ->
            Err (onInternalError err)


cacheRequestResolution :
    RawRequest error value
    -> RequestsAndPending
    -> Status error value
cacheRequestResolution request rawResponses =
    case request of
        Request urlList lookupFn ->
            if List.isEmpty urlList then
                cacheRequestResolution (lookupFn Nothing rawResponses) rawResponses

            else
                Incomplete urlList (Request [] lookupFn)

        ApiRoute value ->
            Complete value

        InternalError err ->
            HasPermanentError (InternalFailure err)


type Status error value
    = Incomplete (List Pages.StaticHttp.Request.Request) (RawRequest error value)
    | HasPermanentError Error
    | Complete (Result error value)
