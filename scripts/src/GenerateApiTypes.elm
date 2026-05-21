module GenerateApiTypes exposing (run)

import BackendTask exposing (BackendTask)
import BackendTask.Do as Do
import Codec
import Dict
import ExtractInternalApi exposing (API)
import FatalError exposing (FatalError)
import Json.Decode
import Pages.Script as Script exposing (Script)


run : Script
run =
    Script.withoutCliOptions task


task : BackendTask FatalError ()
task =
    Do.command "npx" [ "elm-review", "--extract", "--report=json", "--config", "scripts" ] <|
        \output ->
            Do.do
                (case
                    Json.Decode.decodeString
                        (Json.Decode.at [ "extracts", "ExtractInternalApiRule" ] (Codec.decoder ExtractInternalApi.extractCodec))
                        output
                 of
                    Err e ->
                        BackendTask.fail (FatalError.fromString (Json.Decode.errorToString e))

                    Ok v ->
                        BackendTask.succeed v
                )
            <|
                \extract ->
                    Do.each (Dict.toList extract) viewAPI <|
                        \_ ->
                            Do.noop


viewAPI : ( String, API ) -> BackendTask FatalError ()
viewAPI ( name, api ) =
    Script.log (name ++ ":\n" ++ ExtractInternalApi.apiToString api)
