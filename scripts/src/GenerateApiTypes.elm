module GenerateApiTypes exposing (run)

import BackendTask exposing (BackendTask)
import BackendTask.Do as Do
import Codec
import ExtractInternalApi
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
                (case Codec.decodeString ExtractInternalApi.extractCodec output of
                    Err e ->
                        BackendTask.fail (FatalError.fromString (Json.Decode.errorToString e))

                    Ok v ->
                        BackendTask.succeed v
                )
            <|
                \extract ->
                    Script.log ("Extracted: " ++ Debug.toString extract)
