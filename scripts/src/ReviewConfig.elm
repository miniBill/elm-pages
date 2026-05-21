module ReviewConfig exposing (config)

import ExtractInternalApi
import Review.Rule as Rule exposing (Rule)


config : List Rule
config =
    [ ExtractInternalApi.rule |> Rule.ignoreErrorsForDirectories [ "tests" ] ]
