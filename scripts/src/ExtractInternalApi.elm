module ExtractInternalApi exposing
    ( rule
    , extractCodec, API, Body(..)
    , apiToString
    )

{-|

@docs rule

@docs extractCodec, API, Body

-}

import Codec exposing (Codec, Value)
import Dict exposing (Dict)
import Dict.Extra
import Elm.Syntax.Expression as Expression exposing (Expression)
import Elm.Syntax.ModuleName exposing (ModuleName)
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Range exposing (Range)
import Elm.Writer
import Json.Encode
import List.Extra
import Result.Extra
import Review.ModuleNameLookupTable as ModuleNameLookupTable exposing (ModuleNameLookupTable)
import Review.Rule as Rule exposing (Rule)
import String.Extra
import Triple.Extra


{-| Extracts internal API calls.
-}
rule : Rule
rule =
    Rule.newProjectRuleSchema "ExtractInternalApiRule" initialProjectContext
        |> Rule.withModuleVisitor moduleVisitor
        |> Rule.withModuleContextUsingContextCreator
            { fromProjectToModule = fromProjectToModule
            , fromModuleToProject = fromModuleToProject
            , foldProjectContexts = foldProjectContexts
            }
        |> Rule.withDataExtractor
            (\{ calls } ->
                Dict.Extra.filterMap
                    (\k v ->
                        case v of
                            Ok w ->
                                Just w

                            Err _ ->
                                Nothing
                    )
                    calls
                    |> Codec.encodeToValue extractCodec
            )
        |> Rule.withFinalProjectEvaluation finalEvaluation
        |> Rule.fromProjectRuleSchema


finalEvaluation : ProjectContext -> List (Rule.Error { useErrorForModule : () })
finalEvaluation context =
    context.calls
        |> Dict.toList
        |> List.filterMap
            (\( key, value ) ->
                case value of
                    Ok _ ->
                        Nothing

                    Err e ->
                        Just e
            )


extractCodec : Codec (Dict String API)
extractCodec =
    Codec.dict apiCodec


apiCodec : Codec API
apiCodec =
    Codec.object API
        |> Codec.field "body" .body bodyCodec
        |> Codec.field "expect" .expect typeCodec
        |> Codec.buildObject


typeCodec : Codec Type
typeCodec =
    Codec.recursive
        (\rec ->
            Codec.custom
                (\dictTypeEncoder listTypeEncoder nullableTypeEncoder recordTypeEncoder unitTypeEncoder stringTypeEncoder nullTypeEncoder anyTypeEncoder unknownTypeEncoder intTypeEncoder floatTypeEncoder boolTypeEncoder unionTypeEncoder namedTypeEncoder value ->
                    case value of
                        DictType k v ->
                            dictTypeEncoder k v

                        ListType c ->
                            listTypeEncoder c

                        NullableType c ->
                            nullableTypeEncoder c

                        RecordType argA ->
                            recordTypeEncoder argA

                        UnitType ->
                            unitTypeEncoder

                        StringType b ->
                            stringTypeEncoder b

                        NullType ->
                            nullTypeEncoder

                        AnyType ->
                            anyTypeEncoder

                        UnknownType ->
                            unknownTypeEncoder

                        IntType ->
                            intTypeEncoder

                        FloatType ->
                            floatTypeEncoder

                        BoolType b ->
                            boolTypeEncoder b

                        UnionType b ->
                            unionTypeEncoder b

                        NamedType a b ->
                            namedTypeEncoder a b
                )
                |> Codec.variant2 "DictType" DictType rec rec
                |> Codec.variant1 "ListType" ListType rec
                |> Codec.variant1 "NullableType" NullableType rec
                |> Codec.variant1 "RecordType" RecordType (Codec.list (Codec.triple Codec.string rec Codec.bool))
                |> Codec.variant0 "UnitType" UnitType
                |> Codec.variant1 "StringType" StringType (Codec.maybe Codec.string)
                |> Codec.variant0 "NullType" NullType
                |> Codec.variant0 "AnyType" AnyType
                |> Codec.variant0 "UnknownType" UnknownType
                |> Codec.variant0 "IntType" IntType
                |> Codec.variant0 "FloatType" FloatType
                |> Codec.variant1 "BoolType" BoolType (Codec.maybe Codec.bool)
                |> Codec.variant1 "UnionType" UnionType (Codec.list rec)
                |> Codec.variant2 "NamedType" NamedType Codec.string rec
                |> Codec.buildCustom
        )


bodyCodec : Codec Body
bodyCodec =
    Codec.custom
        (\emptyBodyEncoder bytesBodyEncoder unknownBodyEncoder stringBodyEncoder jsonBodyEncoder value ->
            case value of
                EmptyBody ->
                    emptyBodyEncoder

                BytesBody ->
                    bytesBodyEncoder

                UnknownBody ->
                    unknownBodyEncoder

                StringBody ->
                    stringBodyEncoder

                JsonBody argA ->
                    jsonBodyEncoder argA
        )
        |> Codec.variant0 "EmptyBody" EmptyBody
        |> Codec.variant0 "BytesBody" BytesBody
        |> Codec.variant0 "UnknownBody" UnknownBody
        |> Codec.variant0 "StringBody" StringBody
        |> Codec.variant1 "JsonBody" JsonBody typeCodec
        |> Codec.buildCustom


type alias API =
    { body : Body
    , expect : Type
    }


type alias ProjectContext =
    { calls : Dict String (Result (Rule.Error { useErrorForModule : () }) API) }


type alias ModuleContext =
    { lookupTable : ModuleNameLookupTable
    , calls : Dict String API
    }


moduleVisitor : Rule.ModuleRuleSchema schema ModuleContext -> Rule.ModuleRuleSchema { schema | hasAtLeastOneVisitor : () } ModuleContext
moduleVisitor schema =
    schema
        |> Rule.withExpressionEnterVisitor expressionVisitor


initialProjectContext : ProjectContext
initialProjectContext =
    { calls = Dict.empty }


fromProjectToModule : Rule.ContextCreator ProjectContext ModuleContext
fromProjectToModule =
    Rule.initContextCreator
        (\lookupTable projectContext ->
            { lookupTable = lookupTable
            , calls = Dict.empty
            }
        )
        |> Rule.withModuleNameLookupTable


fromModuleToProject : Rule.ContextCreator ModuleContext ProjectContext
fromModuleToProject =
    Rule.initContextCreator
        (\moduleContext ->
            { calls = Dict.map (\_ v -> Ok v) moduleContext.calls }
        )


foldProjectContexts : ProjectContext -> ProjectContext -> ProjectContext
foldProjectContexts new previous =
    { calls =
        Dict.merge
            Dict.insert
            (\k lv rv a ->
                case ( lv, rv ) of
                    ( Err le, _ ) ->
                        Dict.insert k lv a

                    ( _, Err re ) ->
                        Dict.insert k rv a

                    ( Ok lo, Ok ro ) ->
                        if lo == ro then
                            Dict.insert k lv a

                        else
                            case
                                Result.map2 (\body expect -> { body = body, expect = expect })
                                    (intersectBodies lo.body ro.body)
                                    (intersectTypes2 lo.expect ro.expect)
                            of
                                Ok intersection ->
                                    Dict.insert k (Ok intersection) a

                                Err e ->
                                    Dict.insert k (Err (Rule.globalError e)) a
            )
            Dict.insert
            new.calls
            previous.calls
            Dict.empty
    }


intersectBodies : Body -> Body -> Result { message : String, details : List String } Body
intersectBodies l r =
    case ( l, r ) of
        ( UnknownBody, _ ) ->
            Ok r

        ( _, UnknownBody ) ->
            Ok l

        ( EmptyBody, EmptyBody ) ->
            Ok EmptyBody

        ( _, EmptyBody ) ->
            Err (noIntersection l r)

        ( EmptyBody, _ ) ->
            Err (noIntersection l r)

        ( BytesBody, BytesBody ) ->
            Ok BytesBody

        ( JsonBody _, BytesBody ) ->
            Err (noIntersection l r)

        ( BytesBody, JsonBody _ ) ->
            Err (noIntersection l r)

        ( JsonBody lt, JsonBody rt ) ->
            intersectTypes2 lt rt
                |> Result.map JsonBody

        ( StringBody, StringBody ) ->
            Ok StringBody

        ( _, StringBody ) ->
            Err (noIntersection l r)

        ( StringBody, _ ) ->
            Err (noIntersection l r)


noIntersection : Body -> Body -> { message : String, details : List String }
noIntersection l r =
    { message = "No intersection for bodies"
    , details =
        [ l, r ]
            |> List.map (\body -> " - " ++ bodyToString body)
    }


bodyToString : Body -> String
bodyToString body =
    case body of
        EmptyBody ->
            "<empty>"

        BytesBody ->
            "<bytes>"

        UnknownBody ->
            "<unknown>"

        StringBody ->
            "<string>"

        JsonBody t ->
            typeToString_ t


apiToString : API -> String
apiToString api =
    [ " - body: " ++ bodyToString api.body
    , " - expect: " ++ typeToString_ api.expect
    ]
        |> String.join "\n"


expressionVisitor : Node Expression -> ModuleContext -> ( List (Rule.Error {}), ModuleContext )
expressionVisitor (Node range node) context =
    case node of
        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ functionName), arg ] ->
            let
                internalRequest =
                    functionName == "request" || functionName == "requestWithHeaders"
            in
            if internalRequest then
                case moduleNameAt functionRange context of
                    Ok [ "BackendTask", "Internal", "Request" ] ->
                        case arg of
                            Node argRange (Expression.RecordExpr fields) ->
                                let
                                    findField : String -> Result (Rule.Error {}) (Node Expression)
                                    findField name =
                                        case
                                            List.Extra.findMap
                                                (\(Node _ ( Node _ k, v )) ->
                                                    if k == name then
                                                        Just v

                                                    else
                                                        Nothing
                                                )
                                                fields
                                        of
                                            Nothing ->
                                                Rule.error
                                                    { message = "Could not extract the " ++ name ++ " from the record"
                                                    , details = [ "The argument didn't have the expected `" ++ name ++ "` field." ]
                                                    }
                                                    argRange
                                                    |> Err

                                            Just fieldValue ->
                                                Ok fieldValue
                                in
                                case ( findField "name", findField "body", findField "expect" ) of
                                    ( Err e, _, _ ) ->
                                        ( [ e ], context )

                                    ( _, Err e, _ ) ->
                                        ( [ e ], context )

                                    ( _, _, Err e ) ->
                                        ( [ e ], context )

                                    ( Ok (Node _ (Expression.Literal name)), Ok body, Ok expect ) ->
                                        parseRequest range name body expect context

                                    ( Ok (Node nameRange _), _, _ ) ->
                                        ( [ Rule.error
                                                { message = "Could not extract the name from the record"
                                                , details = [ "It wasn't a string." ]
                                                }
                                                nameRange
                                          ]
                                        , context
                                        )

                            Node argRange _ ->
                                ( [ Rule.error
                                        { message = "BackendTask.Internal.Request." ++ functionName ++ " called with a non-record argument"
                                        , details = [ "I expected to see a record as argument, but I've found something else." ]
                                        }
                                        argRange
                                  ]
                                , context
                                )

                    Ok _ ->
                        ( [], context )

                    Err e ->
                        ( [ e ], context )

            else
                ( [], context )

        _ ->
            ( [], context )


parseRequest : Range -> String -> Node Expression -> Node Expression -> ModuleContext -> ( List (Rule.Error {}), ModuleContext )
parseRequest range name body expect context =
    case Result.map2 API (parseBody context body) (parseDecoder context expect) of
        Err e ->
            ( [ e ], context )

        Ok new ->
            case Dict.get name context.calls of
                Nothing ->
                    ( [], { context | calls = Dict.insert name new context.calls } )

                Just existing ->
                    case ( new.body == existing.body, new.expect == existing.expect ) of
                        ( True, True ) ->
                            ( [], context )

                        ( True, False ) ->
                            case intersectTypes2 new.expect existing.expect of
                                Ok intersection ->
                                    ( []
                                    , { context
                                        | calls =
                                            Dict.insert name
                                                { body = existing.body
                                                , expect = intersection
                                                }
                                                context.calls
                                      }
                                    )

                                Err e ->
                                    ( [ Rule.error e range ], context )

                        _ ->
                            ( [ Rule.error
                                    { message = "Conflicting types"
                                    , details =
                                        [ "Found"
                                        , apiToString new
                                        , "but I had already found"
                                        , apiToString existing
                                        , "elsewhere"
                                        ]
                                    }
                                    range
                              ]
                            , context
                            )


type Type
    = ListType Type
    | DictType Type Type
    | NullableType Type
    | RecordType (List ( String, Type, Bool ))
    | UnitType
    | StringType (Maybe String)
    | NullType
    | AnyType
    | UnknownType
    | IntType
    | FloatType
    | BoolType (Maybe Bool)
    | UnionType (List Type)
    | NamedType String Type


type Body
    = EmptyBody
    | BytesBody
    | UnknownBody
    | JsonBody Type
    | StringBody


parseBody : ModuleContext -> Node Expression -> Result (Rule.Error {}) Body
parseBody context (Node range expr) =
    case expr of
        Expression.OperatorApplication "|>" _ l r ->
            parseBody context (Node range (Expression.Application [ r, l ]))

        Expression.OperatorApplication "<|" _ l r ->
            parseBody context (Node range (Expression.Application [ l, r ]))

        Expression.FunctionOrValue _ "emptyBody" ->
            expectModuleNameAt [ "BackendTask", "Http" ] range context
                |> Result.map (\() -> EmptyBody)

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "jsonBody"), tail ] ->
            expectModuleNameAt [ "BackendTask", "Http" ] functionRange context
                |> Result.andThen (\_ -> parseEncoder context tail)
                |> Result.map JsonBody

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "stringBody"), _, _ ] ->
            expectModuleNameAt [ "BackendTask", "Http" ] functionRange context
                |> Result.map (\() -> StringBody)

        Expression.Application ((Node functionRange (Expression.FunctionOrValue _ "bytesBody")) :: tail) ->
            expectModuleNameAt [ "BackendTask", "Http" ] range context
                |> Result.andThen (\() -> missingBranch "parseBody" range expr)

        Expression.Application ((Node functionRange (Expression.FunctionOrValue [] "toInternalStartSpinnerBody")) :: tail) ->
            [ ( "text", StringType Nothing, True )
            , ( "immediateStart", BoolType Nothing, True )
            , ( "spinnerId", StringType Nothing, False )
            , ( "spinner", StringType Nothing, False )
            ]
                |> RecordType
                |> JsonBody
                |> Ok

        Expression.Application ((Node functionRange (Expression.FunctionOrValue [] "toInternalStopSpinnerBody")) :: tail) ->
            let
                completionFn : Type
                completionFn =
                    [ "succeed", "fail", "warn", "info" ]
                        |> List.map (\s -> StringType (Just s))
                        |> UnionType
            in
            [ ( "spinnerId", StringType Nothing, True )
            , ( "completionFn", completionFn, True )
            , ( "completionText", NullableType (StringType Nothing), True )
            ]
                |> RecordType
                |> JsonBody
                |> Ok

        Expression.FunctionOrValue [] "body" ->
            Ok UnknownBody

        _ ->
            missingBranch "parseBody" range expr


parseEncoder : ModuleContext -> Node Expression -> Result (Rule.Error {}) Type
parseEncoder context (Node range expr) =
    case expr of
        Expression.ParenthesizedExpression child ->
            parseEncoder context child

        Expression.OperatorApplication "|>" _ l r ->
            parseEncoder context (Node range (Expression.Application [ r, l ]))

        Expression.OperatorApplication "<|" _ l r ->
            parseEncoder context (Node range (Expression.Application [ l, r ]))

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "object"), Node _ (Expression.ListExpr fields) ] ->
            expectModuleNameAt [ "Json", "Encode" ] functionRange context
                |> Result.andThen
                    (\() ->
                        fields
                            |> Result.Extra.combineMap (parseField context)
                            |> Result.map RecordType
                    )

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "string"), Node _ _ ] ->
            expectModuleNameAt [ "Json", "Encode" ] functionRange context
                |> Result.map (\() -> StringType Nothing)

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "int"), Node _ _ ] ->
            expectModuleNameAt [ "Json", "Encode" ] functionRange context
                |> Result.map (\() -> IntType)

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "float"), Node _ _ ] ->
            expectModuleNameAt [ "Json", "Encode" ] functionRange context
                |> Result.map (\() -> FloatType)

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "bool"), Node _ (Expression.FunctionOrValue [] "True") ] ->
            expectModuleNameAt [ "Json", "Encode" ] functionRange context
                |> Result.map (\() -> BoolType (Just True))

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "bool"), Node _ (Expression.FunctionOrValue [] "False") ] ->
            expectModuleNameAt [ "Json", "Encode" ] functionRange context
                |> Result.map (\() -> BoolType (Just False))

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "bool"), Node _ _ ] ->
            expectModuleNameAt [ "Json", "Encode" ] functionRange context
                |> Result.map (\() -> BoolType Nothing)

        Expression.FunctionOrValue _ "null" ->
            expectModuleNameAt [ "Json", "Encode" ] range context
                |> Result.map (\() -> NullType)

        Expression.FunctionOrValue _ "string" ->
            expectModuleNameAt [ "Json", "Encode" ] range context
                |> Result.map (\() -> StringType Nothing)

        Expression.FunctionOrValue _ "int" ->
            expectModuleNameAt [ "Json", "Encode" ] range context
                |> Result.map (\() -> IntType)

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "list"), child, _ ] ->
            expectModuleNameAt [ "Json", "Encode" ] functionRange context
                |> Result.andThen (\() -> parseEncoder context child)
                |> Result.map ListType

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "screen"), _ ] ->
            expectModuleNameAt [ "Tui", "Screen", "Internal", "Encode" ] functionRange context
                |> Result.map
                    (\() ->
                        ListType
                            (ListType
                                (RecordType
                                    [ ( "text", StringType Nothing, True )
                                    , ( "style", styleType, True )
                                    ]
                                )
                            )
                    )

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "getInterests"), _ ] ->
            expectModuleNameAt [ "Tui", "Sub", "Internal" ] functionRange context
                |> Result.map (\() -> ListType (StringType Nothing))

        Expression.Application [ Node functionRange (Expression.FunctionOrValue [] "encodeNonExpiringPairs"), _ ] ->
            Ok (DictType (StringType Nothing) (StringType Nothing))

        Expression.Application [ Node functionRange (Expression.FunctionOrValue [] "encodeZoneRequest"), _, _, _ ] ->
            [ ( "sinceMs", IntType, True )
            , ( "untilMs", IntType, True )
            , ( "tzId", StringType Nothing, False )
            ]
                |> RecordType
                |> Ok

        Expression.Application [ Node functionRange (Expression.FunctionOrValue [] "pipelineEncoder"), _, _ ] ->
            Ok streamType

        Expression.Application [ Node functionRange (Expression.FunctionOrValue [] "encodeOptions"), _ ] ->
            Ok globOptionsType

        Expression.FunctionOrValue [] "input" ->
            Ok AnyType

        _ ->
            missingBranch "parseEncoder" range expr


globOptionsType : Type
globOptionsType =
    [ ( "dot", BoolType Nothing, True )
    , ( "followSymbolicLinks", BoolType Nothing, True )
    , ( "caseSensitiveMatch", BoolType Nothing, True )
    , ( "gitignore", BoolType Nothing, True )
    , ( "deep", IntType, False )
    , ( "onlyFiles", BoolType Nothing, True )
    , ( "onlyDirectories", BoolType Nothing, True )
    , ( "stats", BoolType Nothing, True )
    ]
        |> RecordType


streamType : Type
streamType =
    let
        single : String -> List ( String, Type, Bool ) -> Type
        single name inner =
            RecordType (( "name", StringType (Just name), True ) :: inner)

        partType : Type
        partType =
            [ single "stdin" []
            , single "stdout" []
            , single "stderr" []
            , single "fileRead" [ ( "path", StringType Nothing, True ) ]
            , single "fileWrite" [ ( "path", StringType Nothing, True ) ]
            , single
                "customRead"
                [ ( "portName", StringType Nothing, True )
                , ( "input", AnyType, True )
                ]
            , single
                "customWrite"
                [ ( "portName", StringType Nothing, True )
                , ( "input", AnyType, True )
                ]
            ]
                |> UnionType
                |> NamedType "StreamPart"
    in
    [ ( "kind", StringType Nothing, True )
    , ( "parts", ListType partType, True )
    ]
        |> RecordType
        |> NamedType "Stream"


styleType : Type
styleType =
    [ ( "bold", BoolType (Just True) )
    , ( "dim", BoolType (Just True) )
    , ( "italic", BoolType (Just True) )
    , ( "underline", BoolType (Just True) )
    , ( "strikethrough", BoolType (Just True) )
    , ( "inverse", BoolType (Just True) )
    , ( "foreground", colorType )
    , ( "background", colorType )
    , ( "hyperlink", StringType Nothing )
    ]
        |> List.map (\( k, v ) -> ( k, v, False ))
        |> RecordType
        |> NamedType "Style"


colorType : Type
colorType =
    let
        strings : List String
        strings =
            [ "black"
            , "red"
            , "green"
            , "yellow"
            , "blue"
            , "magenta"
            , "cyan"
            , "white"
            , "brightBlack"
            , "brightRed"
            , "brightGreen"
            , "brightYellow"
            , "brightBlue"
            , "brightMagenta"
            , "brightCyan"
            , "brightWhite"
            ]
    in
    [ NamedType "KnownColor" (UnionType (List.map (\v -> StringType (Just v)) strings))
    , RecordType [ ( "color256", IntType, True ) ]
    , RecordType
        [ ( "r", IntType, True )
        , ( "g", IntType, True )
        , ( "b", IntType, True )
        ]
    ]
        |> UnionType
        |> NamedType "Color"


parseField : ModuleContext -> Node Expression -> Result (Rule.Error {}) ( String, Type, Bool )
parseField context (Node range expr) =
    case expr of
        Expression.TupledExpression [ Node _ (Expression.Literal fieldName), fieldEncoder ] ->
            fieldEncoder
                |> parseEncoder context
                |> Result.map (\t -> ( fieldName, t, True ))

        _ ->
            missingBranch "parseField" range expr


parseDecoder : ModuleContext -> Node Expression -> Result (Rule.Error {}) Type
parseDecoder context (Node range expr) =
    case expr of
        Expression.OperatorApplication "|>" _ l r ->
            parseDecoder context (Node range (Expression.Application [ r, l ]))

        Expression.ParenthesizedExpression child ->
            parseDecoder context child

        Expression.Application [ Node _ (Expression.Application l), r ] ->
            parseDecoder context (Node range (Expression.Application (l ++ [ r ])))

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "succeed"), Node _ _ ] ->
            expectModuleNameAt [ "Json", "Decode" ] functionRange context
                |> Result.map (\() -> AnyType)

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "null"), Node _ Expression.UnitExpr ] ->
            expectModuleNameAt [ "Json", "Decode" ] functionRange context
                |> Result.map (\() -> NullType)

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "nullable"), child ] ->
            Result.map2 (\() t -> NullableType t)
                (expectModuleNameAt [ "Json", "Decode" ] functionRange context)
                (parseDecoder context child)

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "maybe"), child ] ->
            Result.map2 (\() t -> NullableType t)
                (expectModuleNameAt [ "Json", "Decode" ] functionRange context)
                (parseDecoder context child)

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "list"), child ] ->
            Result.map2 (\() t -> ListType t)
                (expectModuleNameAt [ "Json", "Decode" ] functionRange context)
                (parseDecoder context child)

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "map"), _, child ] ->
            expectModuleNameAt [ "Json", "Decode" ] functionRange context
                |> Result.andThen (\() -> parseDecoder context child)

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "map2"), _, child1, child2 ] ->
            Result.map3
                (\() l r -> [ l, r ])
                (expectModuleNameAt [ "Json", "Decode" ] functionRange context)
                (parseDecoder context child1)
                (parseDecoder context child2)
                |> Result.andThen (intersectTypes range)

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "map3"), _, child1, child2, child3 ] ->
            Result.map4
                (\() l m r -> [ l, m, r ])
                (expectModuleNameAt [ "Json", "Decode" ] functionRange context)
                (parseDecoder context child1)
                (parseDecoder context child2)
                (parseDecoder context child3)
                |> Result.andThen (intersectTypes range)

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "oneOf"), Node _ (Expression.ListExpr oneOf) ] ->
            Result.map2
                (\() children -> UnionType children)
                (expectModuleNameAt [ "Json", "Decode" ] functionRange context)
                (Result.Extra.combineMap (parseDecoder context) oneOf)

        Expression.Application [ Node functionRange (Expression.FunctionOrValue _ "field"), Node _ (Expression.Literal fieldName), child ] ->
            expectModuleNameAt [ "Json", "Decode" ] functionRange context
                |> Result.andThen (\() -> parseDecoder context child)
                |> Result.map (\fieldType -> RecordType [ ( fieldName, fieldType, True ) ])

        Expression.Application [ Node functionRange (Expression.FunctionOrValue [] "decodeLog"), child ] ->
            parseDecoder context child

        Expression.FunctionOrValue _ "value" ->
            expectModuleNameAt [ "Json", "Decode" ] range context
                |> Result.map (\() -> AnyType)

        Expression.FunctionOrValue _ "string" ->
            expectModuleNameAt [ "Json", "Decode" ] range context
                |> Result.map (\() -> StringType Nothing)

        Expression.FunctionOrValue _ "int" ->
            expectModuleNameAt [ "Json", "Decode" ] range context
                |> Result.map (\() -> IntType)

        Expression.FunctionOrValue _ "bool" ->
            expectModuleNameAt [ "Json", "Decode" ] range context
                |> Result.map (\() -> BoolType Nothing)

        Expression.FunctionOrValue [] "decodeColorProfile" ->
            Ok (StringType Nothing)

        Expression.FunctionOrValue [] "zoneDecoder" ->
            [ ( "defaultOffset", IntType, True )
            , ( "eras"
              , ListType
                    (RecordType
                        [ ( "start", IntType, True )
                        , ( "offset", IntType, True )
                        ]
                    )
              , True
              )
            ]
                |> RecordType
                |> Ok

        Expression.FunctionOrValue [] "fileStatsDecoder" ->
            Ok fileStatsType

        Expression.FunctionOrValue [] "decoder" ->
            -- TODO: fix
            Ok UnknownType

        Expression.FunctionOrValue [] "metadataDecoder" ->
            -- TODO: fix
            Ok UnknownType

        Expression.Application [ Node functionRange (Expression.FunctionOrValue [] "internalErrorDecoder"), _, _ ] ->
            -- TODO: fix
            Ok
                (UnionType
                    [ NamedType "InternalError" internalErrorType
                    , AnyType
                    ]
                )

        Expression.Application [ Node functionRange (Expression.FunctionOrValue [] "errorDecoder"), _ ] ->
            Ok AnyType

        Expression.Application [ Node functionRange (Expression.FunctionOrValue [] "streamReadDecoder"), _ ] ->
            Ok
                (UnionType
                    [ RecordType [ ( "error", StringType Nothing, True ) ]
                    , RecordType
                        [ ( "metadata", AnyType, True )
                        , ( "body"
                          , StringType Nothing
                          , False
                          )
                        ]
                    , AnyType
                    ]
                )

        _ ->
            missingBranch "parseDecoder" range expr


internalErrorType : Type
internalErrorType =
    let
        one : String -> List ( String, Type, Bool ) -> Type
        one name other =
            RecordType
                (( "elm-pages-internal-error", StringType (Just name), True )
                    :: other
                )
    in
    [ one "CustomBackendTaskNotDefined" []
    , one "ExportIsNotFunction" [ ( "error", StringType Nothing, False ) ]
    , one "MissingCustomBackendTaskFile" []
    , one "ErrorInCustomBackendTaskFile" [ ( "error", StringType Nothing, False ) ]
    , one "CustomBackendTaskException" [ ( "error", StringType Nothing, False ) ]
    , one "NonJsonException"
        [ ( "error", StringType Nothing, True )
        , ( "stack", NullableType (StringType Nothing), True )
        ]
    ]
        |> UnionType


fileStatsType : Type
fileStatsType =
    [ ( "fullPath", StringType Nothing, True )
    , ( "size", IntType, True )
    , ( "mtime", IntType, True )
    , ( "atime", IntType, True )
    , ( "ctime", IntType, True )
    , ( "birthtime", IntType, True )
    , ( "isDirectory", BoolType Nothing, True )
    ]
        |> RecordType
        |> NamedType "FileStats"


intersectTypes : Range -> List Type -> Result (Rule.Error {}) Type
intersectTypes range types =
    case types of
        [] ->
            Ok AnyType

        [ x ] ->
            Ok x

        h1 :: h2 :: t ->
            case intersectTypes2 h1 h2 of
                Ok h ->
                    intersectTypes range (h :: t)

                Err e ->
                    Err (Rule.error e range)


intersectTypes2 : Type -> Type -> Result { message : String, details : List String } Type
intersectTypes2 l r =
    case ( l, r ) of
        ( AnyType, _ ) ->
            Ok r

        ( _, AnyType ) ->
            Ok l

        ( UnknownType, _ ) ->
            Ok r

        ( _, UnknownType ) ->
            Ok l

        ( UnionType opts, _ ) ->
            if List.member r opts then
                Ok r

            else
                opts
                    |> Result.Extra.combineMap (\opt -> intersectTypes2 opt r)
                    |> Result.map UnionType

        ( _, UnionType opts ) ->
            if List.member l opts then
                Ok l

            else
                opts
                    |> Result.Extra.combineMap (\opt -> intersectTypes2 l opt)
                    |> Result.map UnionType

        ( RecordType lf, RecordType rf ) ->
            Dict.merge
                (\k v -> Result.map (Dict.insert k v))
                (\k ( v1, o1 ) ( v2, o2 ) a ->
                    if v1 == v2 then
                        Result.map (Dict.insert k ( v1, o1 && o2 )) a

                    else
                        case intersectTypes2 v1 v2 of
                            Err e ->
                                let
                                    msg : String
                                    msg =
                                        "Field `"
                                            ++ k
                                            ++ "` has types `"
                                            ++ typeToString_ v1
                                            ++ "` and `"
                                            ++ typeToString_ v2
                                            ++ "`"
                                in
                                { message = "Incompatible types"
                                , details = msg :: e.details
                                }
                                    |> Err

                            Ok vi ->
                                Result.map (Dict.insert k ( vi, o1 && o2 )) a
                )
                (\k v -> Result.map (Dict.insert k v))
                (lf |> List.map (\( k, v, m ) -> ( k, ( v, m ) )) |> Dict.fromList)
                (rf |> List.map (\( k, v, m ) -> ( k, ( v, m ) )) |> Dict.fromList)
                (Ok Dict.empty)
                |> Result.map
                    (\d ->
                        d
                            |> Dict.toList
                            |> List.map (\( k, ( v, m ) ) -> ( k, v, m ))
                            |> RecordType
                    )

        _ ->
            { message = "intersectTypes2 - Missing branch"
            , details = [ "Branch `" ++ typeToString_ l ++ "` `" ++ typeToString_ r ++ "` not implemented" ]
            }
                |> Err


typeToString_ : Type -> String
typeToString_ t =
    Tuple.first (typeToString False t)


typeToString : Bool -> Type -> ( String, Dict String Type )
typeToString isInUnion t =
    let
        map f l =
            typeToString False l
                |> Tuple.mapFirst f

        map2 f l r =
            let
                ( ls, ld ) =
                    typeToString False l

                ( rs, rd ) =
                    typeToString False r
            in
            ( f ls rs, Dict.union ld rd )
    in
    case t of
        DictType k v ->
            map2
                (\ks vs ->
                    "{ [ key: " ++ ks ++ "]: " ++ vs ++ " }"
                )
                k
                v

        ListType c ->
            map (\cs -> cs ++ "[]") c

        NullableType c ->
            map (\cs -> cs ++ "?") c

        RecordType fields ->
            let
                ( inner, dict ) =
                    fields
                        |> List.map
                            (\( k, v, o ) ->
                                map
                                    (\vs ->
                                        if o then
                                            k ++ ": " ++ vs ++ "; "

                                        else
                                            k ++ "? : " ++ vs ++ "; "
                                    )
                                    v
                            )
                        |> List.unzip
                        |> Tuple.mapBoth String.concat (List.foldl Dict.union Dict.empty)
            in
            if String.isEmpty inner then
                ( "{}", dict )

            else
                ( "{ " ++ inner ++ "}", dict )

        UnitType ->
            ( "{}", Dict.empty )

        StringType (Just l) ->
            ( Json.Encode.encode 0 (Json.Encode.string l), Dict.empty )

        StringType Nothing ->
            ( "string", Dict.empty )

        NullType ->
            ( "null", Dict.empty )

        AnyType ->
            ( "any", Dict.empty )

        UnknownType ->
            ( "unknown", Dict.empty )

        IntType ->
            ( "number", Dict.empty )

        FloatType ->
            ( "number", Dict.empty )

        BoolType (Just True) ->
            ( "true", Dict.empty )

        BoolType (Just False) ->
            ( "false", Dict.empty )

        BoolType Nothing ->
            ( "boolean", Dict.empty )

        UnionType ls ->
            let
                ( inner, dict ) =
                    ls
                        |> List.map (typeToString True)
                        |> List.unzip
                        |> Tuple.mapBoth (String.join "|") (List.foldl Dict.union Dict.empty)
            in
            if isInUnion then
                ( "(" ++ inner ++ ")", dict )

            else
                ( inner, dict )

        NamedType name child ->
            ( name, Dict.singleton name child )


missingBranch : String -> Range -> Expression -> Result (Rule.Error {}) t
missingBranch label range expr =
    Rule.error
        { message = label ++ " - Missing branch"
        , details = [ "Branch `" ++ expressionToString expr ++ "` not implemented" ]
        }
        range
        |> Err


expressionToString : Expression -> String
expressionToString expr =
    Elm.Writer.writeExpression (Node.empty expr)
        |> Elm.Writer.write


expectModuleNameAt : ModuleName -> Range -> ModuleContext -> Result (Rule.Error {}) ()
expectModuleNameAt expected range context =
    case moduleNameAt range context of
        Ok found ->
            if found == expected then
                Ok ()

            else
                Rule.error
                    { message = "Unexpected module name"
                    , details =
                        [ "I expected `"
                            ++ String.join "." expected
                            ++ "`, but found `"
                            ++ String.join "." found
                            ++ "`"
                        ]
                    }
                    range
                    |> Err

        Err e ->
            Err e


moduleNameAt : Range -> ModuleContext -> Result (Rule.Error {}) ModuleName
moduleNameAt range context =
    case ModuleNameLookupTable.moduleNameAt context.lookupTable range of
        Just name ->
            Ok name

        Nothing ->
            Rule.error
                { message = "Could not find module name for function call"
                , details = [ "I tried looking up the module that the function call comes from but I failed to do so." ]
                }
                range
                |> Err
