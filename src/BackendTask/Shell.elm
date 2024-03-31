module BackendTask.Shell exposing
    ( sh
    , Command, command, pipe
    , stdout, run, text
    , tryJson, map, tryMap
    , binary
    , exec
    , withTimeout
    )

{-|

@docs sh


## Building Commands

For more sophisticated commands, you can build a `Command` using the `command` function, which you can then use to
pipe together multiple `Command`s, and to capture or decode their final output.

@docs Command, command, pipe


## Capturing Output

@docs stdout, run, text


## Output Decoders

@docs tryJson, map, tryMap

@docs binary


## Executing Commands

@docs exec

@docs withTimeout

-}

import BackendTask exposing (BackendTask)
import BackendTask.Http
import BackendTask.Internal.Request
import Base64
import Bytes exposing (Bytes)
import FatalError exposing (FatalError)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


{-| -}
command : String -> List String -> Command String
command command_ args =
    Command
        { command = [ subCommand command_ args ]
        , quiet = False
        , timeout = Nothing
        , decoder = Ok
        }


subCommand : String -> List String -> SubCommand
subCommand command_ args =
    { command = command_
    , args = args
    , timeout = Nothing
    }


type alias SubCommand =
    { command : String
    , args : List String
    , timeout : Maybe Int
    }


{-| A shell command which can be executed, or piped together with other commands.
-}
type Command stdout
    = Command
        { command : List SubCommand
        , quiet : Bool
        , timeout : Maybe Int
        , decoder : String -> Result String stdout
        }


{-| -}
map : (a -> b) -> Command a -> Command b
map mapFn (Command command_) =
    Command
        { command = command_.command
        , quiet = command_.quiet
        , timeout = command_.timeout
        , decoder = command_.decoder >> Result.map mapFn
        }


{-| -}
tryMap : (a -> Result String b) -> Command a -> Command b
tryMap mapFn (Command command_) =
    Command
        { command = command_.command
        , quiet = command_.quiet
        , timeout = command_.timeout
        , decoder = command_.decoder >> Result.andThen mapFn
        }


{-| -}
binary : Command String -> Command Bytes
binary (Command command_) =
    Command
        { command = command_.command
        , quiet = command_.quiet
        , timeout = command_.timeout
        , decoder = Base64.toBytes >> Result.fromMaybe "Failed to decode base64 output."
        }


{-| Applies to each individual command in the pipeline.
-}
withTimeout : Int -> Command stdout -> Command stdout
withTimeout timeout (Command command_) =
    Command { command_ | timeout = Just timeout }


{-| -}
text : Command stdout -> BackendTask FatalError String
text command_ =
    command_
        |> run
        |> BackendTask.map .stdout
        |> BackendTask.quiet
        |> BackendTask.allowFatal



--redirect : Command -> ???


{-| Runs the command (which could be a pipeline of sub-commands), and captures stdout from the final portion of the pipeline.
Then decodes stdout using any decoder used to transform the value, or fails with a `FatalError` if the decoder fails.

    import BackendTask.Shell as Shell exposing (Command)

    example : BackendTask FatalError String
    example =
        Shell.command "ls" [ "-l" ]
            |> Shell.stdout

Note that the output for intermediary commands in the pipeline is not captured but rather is piped through directly
to the next command in the pipeline. So every time you use `pipe` to add to the pipeline you are overwriting the decoder.

For example, we could define a command for counting lines using `wc`:

    countLines : Shell.Command Int
    countLines =
        Shell.command "wc" [ "-l" ]
            |> Shell.tryMap
                (\count ->
                    count
                        |> String.toInt
                        |> Result.fromMaybe "Failed to parse line count"
                )

If we use `countLines` at the very end of any pipeline, `stdout` will give us an `Int`.

    import BackendTask.Shell as Shell exposing (Command)

    example : BackendTask FatalError Int
    example =
        Shell.command "ls" [ "-l" ]
            |> Shell.pipe countLines
            |> Shell.stdout

-}
stdout : Command stdout -> BackendTask FatalError stdout
stdout ((Command command_) as fullCommand) =
    fullCommand
        |> run
        |> BackendTask.quiet
        |> BackendTask.allowFatal
        |> BackendTask.andThen
            (\output ->
                case output.stdout |> command_.decoder of
                    Ok okStdout ->
                        BackendTask.succeed okStdout

                    Err message ->
                        BackendTask.fail
                            (FatalError.build
                                { title = "stdout decoder failed"
                                , body = "The stdout decoder failed with the following message: \n\n" ++ message
                                }
                            )
            )


{-| -}
pipe : Command to -> Command from -> Command to
pipe (Command to) (Command from) =
    Command
        { command = from.command ++ to.command
        , quiet = to.quiet
        , timeout = to.timeout
        , decoder = to.decoder
        }


{-| -}
run :
    Command stdout
    ->
        BackendTask
            { fatal : FatalError
            , recoverable : { output : String, stderr : String, stdout : String, statusCode : Int }
            }
            { output : String, stderr : String, stdout : String }
run (Command options_) =
    shell__ options_.command True


{-| -}
exec : Command stdout -> BackendTask FatalError ()
exec (Command options_) =
    shell__ options_.command False
        |> BackendTask.allowFatal
        |> BackendTask.map (\_ -> ())


{-| -}
tryJson : Decoder a -> Command String -> Command a
tryJson jsonDecoder command_ =
    command_
        |> tryMap
            (\jsonString ->
                jsonString
                    |> Decode.decodeString jsonDecoder
                    |> Result.mapError Decode.errorToString
            )


{-| The simplest way to execute a shell command when you don't need to capture its output or do more sophisticated error handling.

This behaves similarly to running a simple command in a shell script. For example, if you have a bash script like this:

```bash
#!/bin/bash

elm make example/Main.elm --output=/dev/null
```

You will see the output of the `elm make` command in the console, and if the command fails, the script will fail with a non-zero exit code.

Similarly in this example, the `Shell.sh` command runs `elm make` and prints the output to the console.
If the command fails, the script will fail with the `FatalError` that `Shell.sh` returns because of the command's non-zero exit code.

    module MyScript exposing (run)

    import BackendTask.Shell
    import Pages.Script as Script exposing (Script)

    run : Script
    run =
        Script.withoutCliOptions
            (Shell.sh
                "elm"
                [ "make"
                , "example/Main.elm"
                , "--output=/dev/null"
                ]
            )

-}
sh : String -> List String -> BackendTask FatalError ()
sh command_ args =
    command command_ args |> exec


{-| -}
shell__ :
    List SubCommand
    -> Bool
    ->
        BackendTask
            { fatal : FatalError
            , recoverable :
                { output : String
                , stderr : String
                , stdout : String
                , statusCode : Int
                }
            }
            { output : String
            , stderr : String
            , stdout : String
            }
shell__ commandsAndArgs captureOutput =
    BackendTask.Internal.Request.request
        { name = "shell"
        , body = BackendTask.Http.jsonBody (commandsAndArgsEncoder commandsAndArgs captureOutput)
        , expect = BackendTask.Http.expectJson commandDecoder
        }
        |> BackendTask.andThen
            (\rawOutput ->
                if rawOutput.exitCode == 0 then
                    BackendTask.succeed
                        { output = rawOutput.output
                        , stderr = rawOutput.stderr
                        , stdout = rawOutput.stdout
                        }

                else
                    FatalError.recoverable { title = "Shell command error", body = "Exit status was " ++ String.fromInt rawOutput.exitCode }
                        { output = rawOutput.output
                        , stderr = rawOutput.stderr
                        , stdout = rawOutput.stdout
                        , statusCode = rawOutput.exitCode
                        }
                        |> BackendTask.fail
            )


commandsAndArgsEncoder : List SubCommand -> Bool -> Encode.Value
commandsAndArgsEncoder commandsAndArgs captureOutput =
    Encode.object
        [ ( "captureOutput", Encode.bool captureOutput )
        , ( "commands"
          , Encode.list
                (\sub ->
                    Encode.object
                        [ ( "command", Encode.string sub.command )
                        , ( "args", Encode.list Encode.string sub.args )
                        , ( "timeout", sub.timeout |> nullable Encode.int )
                        ]
                )
                commandsAndArgs
          )
        ]


nullable : (a -> Encode.Value) -> Maybe a -> Encode.Value
nullable encoder =
    Maybe.map encoder >> Maybe.withDefault Encode.null


type alias RawOutput =
    { exitCode : Int
    , output : String
    , stderr : String
    , stdout : String
    }


commandDecoder : Decoder RawOutput
commandDecoder =
    Decode.map4 RawOutput
        (Decode.field "errorCode" Decode.int)
        (Decode.field "output" Decode.string)
        (Decode.field "stderrOutput" Decode.string)
        (Decode.field "stdoutOutput" Decode.string)
