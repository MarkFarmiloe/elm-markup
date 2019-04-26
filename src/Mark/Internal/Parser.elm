module Mark.Internal.Parser exposing
    ( Replacement(..)
    , addToChildren
    , attribute
    , attributeList
    , blocksOrNewlines
    , buildTree
    , float
    , getFailableBlock
    , getPosition
    , getRangeAndSource
    , indentedBlocksOrNewlines
    , indentedString
    , int
    , newline
    , newlineWith
    , oneOf
    , peek
    , raggedIndentedStringAbove
    , skipBlankLineWith
    , styledText
    , withIndent
    , withRange
    , withRangeResult
    , word
    )

{-| -}

import Mark.Internal.Description exposing (..)
import Mark.Internal.Error as Error exposing (Context(..), Problem(..))
import Mark.Internal.Id as Id exposing (..)
import Mark.Internal.TolerantParser as Tolerant
import Parser.Advanced as Parser exposing ((|.), (|=), Parser)


newlineWith x =
    Parser.token (Parser.Token "\n" (Expecting x))


newline =
    Parser.token (Parser.Token "\n" Newline)


{-| -}
type alias Position =
    { offset : Int
    , line : Int
    , column : Int
    }


{-| -}
type alias Range =
    { start : Position
    , end : Position
    }


int : Parser Context Problem (Found Int)
int =
    Parser.map
        (\result ->
            case result of
                Ok details ->
                    Found details.range details.value

                Err details ->
                    Unexpected
                        { range = details.range
                        , problem = Error.BadInt
                        }
        )
        (withRangeResult
            integer
        )


integer =
    Parser.oneOf
        [ Parser.succeed
            (\i str ->
                if str == "" then
                    Ok (negate i)

                else
                    Err InvalidNumber
            )
            |. Parser.token (Parser.Token "-" (Expecting "-"))
            |= Parser.int Integer InvalidNumber
            |= Parser.getChompedString (Parser.chompWhile (\c -> c /= ' ' && c /= '\n'))
        , Parser.succeed
            (\i str ->
                if str == "" then
                    Ok i

                else
                    Err InvalidNumber
            )
            |= Parser.int Integer InvalidNumber
            |= Parser.getChompedString (Parser.chompWhile (\c -> c /= ' ' && c /= '\n'))
        , Parser.succeed (Err InvalidNumber)
            |. word
        ]


{-| Parses a float and must end with whitespace, not additional characters.
-}
float : Parser Context Problem (Found ( String, Float ))
float =
    Parser.map
        (\result ->
            case result of
                Ok details ->
                    Found details.range details.value

                Err details ->
                    Unexpected
                        { range = details.range
                        , problem = Error.BadFloat
                        }
        )
        (withRangeResult
            floating
        )


floating =
    Parser.oneOf
        [ Parser.succeed
            (\start fl end src extra ->
                if extra == "" then
                    Ok ( String.slice start end src, negate fl )

                else
                    Err InvalidNumber
            )
            |= Parser.getOffset
            |. Parser.token (Parser.Token "-" (Expecting "-"))
            |= Parser.float FloatingPoint InvalidNumber
            |= Parser.getOffset
            |= Parser.getSource
            |= Parser.getChompedString (Parser.chompWhile (\c -> c /= ' ' && c /= '\n'))
        , Parser.succeed
            (\start fl end src extra ->
                if extra == "" then
                    Ok ( String.slice start end src, fl )

                else
                    Err InvalidNumber
            )
            |= Parser.getOffset
            |= Parser.float FloatingPoint InvalidNumber
            |= Parser.getOffset
            |= Parser.getSource
            |= Parser.getChompedString (Parser.chompWhile (\c -> c /= ' ' && c /= '\n'))
        , Parser.succeed (Err InvalidNumber)
            |. word
        ]


{-| -}
indentedString : Int -> String -> Parser Context Problem (Parser.Step String String)
indentedString indentation found =
    Parser.oneOf
        -- First line, indentation is already handled by the block constructor.
        [ Parser.succeed (Parser.Done found)
            |. Parser.end End
        , Parser.succeed
            (\extra ->
                Parser.Loop <|
                    if extra then
                        found ++ "\n\n"

                    else
                        found ++ "\n"
            )
            |. newline
            |= Parser.oneOf
                [ Parser.succeed True
                    |. Parser.backtrackable (Parser.chompWhile (\c -> c == ' '))
                    |. Parser.backtrackable (Parser.token (Parser.Token "\n" Newline))
                , Parser.succeed False
                ]
        , if found == "" then
            Parser.succeed (\str -> Parser.Loop (found ++ str))
                |= Parser.getChompedString
                    (Parser.chompWhile
                        (\c -> c /= '\n')
                    )

          else
            Parser.succeed
                (\str ->
                    Parser.Loop (found ++ str)
                )
                |. Parser.token (Parser.Token (String.repeat indentation " ") (ExpectingIndentation indentation))
                |= Parser.getChompedString
                    (Parser.chompWhile
                        (\c -> c /= '\n')
                    )
        , Parser.succeed (Parser.Done found)
        ]


{-| -}
raggedIndentedStringAbove : Int -> String -> Parser Context Problem (Parser.Step String String)
raggedIndentedStringAbove indentation found =
    Parser.oneOf
        [ Parser.succeed
            (\extra ->
                Parser.Loop <|
                    if extra then
                        found ++ "\n\n"

                    else
                        found ++ "\n"
            )
            |. Parser.token (Parser.Token "\n" Newline)
            |= Parser.oneOf
                [ Parser.succeed True
                    |. Parser.backtrackable (Parser.chompWhile (\c -> c == ' '))
                    |. Parser.backtrackable (Parser.token (Parser.Token "\n" Newline))
                , Parser.succeed False
                ]
        , Parser.succeed
            (\indentCount str ->
                if indentCount <= 0 then
                    Parser.Done found

                else
                    Parser.Loop (found ++ String.repeat indentCount " " ++ str)
            )
            |= Parser.oneOf (indentationBetween (indentation + 1) (indentation + 4))
            |= Parser.getChompedString
                (Parser.chompWhile
                    (\c -> c /= '\n')
                )
        , Parser.succeed (Parser.Done found)
        ]


{-| Parse any indentation between two bounds, inclusive.
-}
indentationBetween : Int -> Int -> List (Parser Context Problem Int)
indentationBetween lower higher =
    let
        bottom =
            min lower higher

        top =
            max lower higher
    in
    List.reverse
        (List.map
            (\numSpaces ->
                Parser.succeed numSpaces
                    |. Parser.token
                        (Parser.Token (String.repeat numSpaces " ")
                            (ExpectingIndentation numSpaces)
                        )
            )
            (List.range bottom top)
        )


oneOf blocks expectations seed =
    let
        gatherParsers myBlock details =
            let
                ( currentSeed, parser ) =
                    case myBlock of
                        Block name blk ->
                            blk.parser details.seed

                        Value val ->
                            val.parser details.seed
            in
            case blockName myBlock of
                Just name ->
                    { blockNames = name :: details.blockNames
                    , childBlocks = parser :: details.childBlocks
                    , childValues = details.childValues
                    , seed = currentSeed
                    }

                Nothing ->
                    { blockNames = details.blockNames
                    , childBlocks = details.childBlocks
                    , childValues = Parser.map Ok parser :: details.childValues
                    , seed = currentSeed
                    }

        children =
            List.foldl gatherParsers
                { blockNames = []
                , childBlocks = []
                , childValues = []
                , seed = newSeed
                }
                blocks

        blockParser =
            failableBlocks
                { names = children.blockNames
                , parsers = children.childBlocks
                }

        ( parentId, newSeed ) =
            Id.step seed
    in
    ( children.seed
    , Parser.succeed
        (\result ->
            case result of
                Ok details ->
                    OneOf
                        { choices = expectations
                        , child = Found details.range details.value
                        , id = parentId
                        }

                Err details ->
                    OneOf
                        { choices = expectations
                        , child =
                            Unexpected
                                { range = details.range
                                , problem = details.error
                                }
                        , id = parentId
                        }
        )
        |= withRangeResult
            (Parser.oneOf
                (blockParser :: List.reverse (unexpectedInOneOf expectations :: children.childValues))
            )
    )


unexpectedInOneOf expectations =
    withIndent
        (\indentation ->
            Parser.succeed
                (\( pos, foundWord ) ->
                    Err (Error.FailMatchOneOf (List.map humanReadableExpectations expectations))
                )
                |= withRange word
        )


getFailableBlock seed fromBlock =
    case fromBlock of
        Block name { parser } ->
            let
                ( newSeed, blockParser ) =
                    parser seed
            in
            ( newSeed
            , failableBlocks
                { names = [ name ]
                , parsers =
                    [ blockParser
                    ]
                }
            )

        Value { parser } ->
            Tuple.mapSecond (Parser.map Ok) (parser seed)


{-| This parser will either:

    - Parse one of the blocks
    - Fail to parse a `|` and continue on
    - Parse a `|`, fail to parse the rest and return an Error

-}
failableBlocks blocks =
    Parser.succeed identity
        |. Parser.token (Parser.Token "|>" BlockStart)
        |. Parser.chompWhile (\c -> c == ' ')
        |= Parser.oneOf
            (List.map (Parser.map Ok) blocks.parsers
                ++ [ withIndent
                        (\indentation ->
                            Parser.succeed
                                (Err (Error.UnknownBlock blocks.names))
                                |. word
                                |. Parser.chompWhile (\c -> c == ' ')
                                |. newline
                                |. Parser.loop "" (raggedIndentedStringAbove indentation)
                        )
                   ]
            )



{- TEXT PARSING -}


{-| -}
type TextCursor
    = TextCursor
        { current : Text
        , start : Position
        , found : List TextDescription
        , balancedReplacements : List String
        }


type SimpleTextCursor
    = SimpleTextCursor
        { current : Text
        , start : Position
        , text : List Text
        , balancedReplacements : List String
        }


mapTextCursor fn (TextCursor curs) =
    TextCursor (fn curs)


{-| -}
type Replacement
    = Replacement String String
    | Balanced
        { start : ( String, String )
        , end : ( String, String )
        }


empty : Text
empty =
    Text emptyStyles ""


textCursor inheritedStyles startingPos =
    TextCursor
        { current = Text inheritedStyles ""
        , found = []
        , start = startingPos
        , balancedReplacements = []
        }


styledText :
    { inlines : List InlineExpectation
    , replacements : List Replacement
    }
    -> Id.Seed
    -> Position
    -> Styling
    -> List Char
    -> Parser Context Problem Description
styledText options seed startingPos inheritedStyles until =
    let
        vacantText =
            textCursor inheritedStyles startingPos

        untilStrings =
            List.map String.fromChar until

        meaningful =
            '\\' :: '\n' :: until ++ stylingChars ++ replacementStartingChars options.replacements

        ( newId, newSeed ) =
            Id.step seed

        -- TODO: return new seed!
    in
    Parser.oneOf
        [ -- Parser.chompIf (\c -> c == ' ') CantStartTextWithSpace
          -- -- TODO: return error description
          -- |> Parser.andThen
          --     (\_ ->
          --         Parser.problem CantStartTextWithSpace
          --     )
          Parser.map
            (\( pos, textNodes ) ->
                DescribeText
                    { id = newId
                    , range = pos
                    , text = textNodes
                    }
            )
            (withRange
                (Parser.loop vacantText
                    (styledTextLoop options meaningful untilStrings)
                )
            )
        ]


{-| -}
styledTextLoop :
    { inlines : List InlineExpectation
    , replacements : List Replacement
    }
    -> List Char
    -> List String
    -> TextCursor
    -> Parser Context Problem (Parser.Step TextCursor (List TextDescription))
styledTextLoop options meaningful untilStrings found =
    Parser.oneOf
        [ Parser.oneOf (replace options.replacements found)
            |> Parser.map Parser.Loop

        -- If a char matches the first character of a replacement,
        -- but didn't match the full replacement captured above,
        -- then stash that char.
        , Parser.oneOf (almostReplacement options.replacements found)
            |> Parser.map Parser.Loop

        -- Capture style command characters
        , Parser.succeed
            (Parser.Loop << changeStyle found)
            |= Parser.oneOf
                [ Parser.map (always Italic) (Parser.token (Parser.Token "/" (Expecting "/")))
                , Parser.map (always Strike) (Parser.token (Parser.Token "~" (Expecting "~")))
                , Parser.map (always Bold) (Parser.token (Parser.Token "*" (Expecting "*")))
                ]

        -- `verbatim`{label| attr = maybe this is here}
        , Parser.succeed
            (\start verbatimString maybeToken end ->
                case maybeToken of
                    Nothing ->
                        let
                            note =
                                InlineVerbatim
                                    { name = Nothing
                                    , text = Text emptyStyles verbatimString
                                    , range =
                                        { start = start
                                        , end = end
                                        }
                                    , attributes = []
                                    }
                        in
                        found
                            |> commitText
                            |> addToTextCursor note
                            |> advanceTo end
                            |> Parser.Loop

                    Just (Err errors) ->
                        let
                            note =
                                InlineVerbatim
                                    { name = Nothing
                                    , text = Text emptyStyles verbatimString
                                    , range =
                                        { start = start
                                        , end = end
                                        }
                                    , attributes = []
                                    }
                        in
                        found
                            |> commitText
                            |> addToTextCursor note
                            |> advanceTo end
                            |> Parser.Loop

                    Just (Ok ( name, attrs )) ->
                        let
                            note =
                                InlineVerbatim
                                    { name = Just name
                                    , text = Text emptyStyles verbatimString
                                    , range =
                                        { start = start
                                        , end = end
                                        }
                                    , attributes = attrs
                                    }
                        in
                        found
                            |> commitText
                            |> addToTextCursor note
                            |> advanceTo end
                            |> Parser.Loop
            )
            |= getPosition
            |. Parser.token (Parser.Token "`" (Expecting "`"))
            |= Parser.getChompedString
                (Parser.chompWhile (\c -> c /= '`' && c /= '\n'))
            |. Parser.chompWhile (\c -> c == '`')
            |= Parser.oneOf
                [ Parser.map Just
                    (attrContainer
                        { attributes = List.filterMap onlyVerbatim options.inlines
                        , onError = Tolerant.skip
                        }
                    )
                , Parser.succeed Nothing
                ]
            |= getPosition

        -- {token| withAttributes = True}
        , Parser.succeed
            (\tokenResult ->
                case tokenResult of
                    Err details ->
                        let
                            er =
                                UnexpectedInline
                                    { range = details.range
                                    , problem =
                                        Error.UnknownInline
                                            (options.inlines
                                                |> List.map inlineExample
                                            )

                                    -- TODO: FIX THIS
                                    --
                                    -- TODO: This is the wrong error
                                    -- It could be:
                                    --   unexpected attributes
                                    --   missing control characters
                                    }
                        in
                        found
                            |> commitText
                            |> addToTextCursor er
                            |> advanceTo details.range.end
                            |> Parser.Loop

                    Ok details ->
                        let
                            note =
                                InlineToken
                                    { name = Tuple.first details.value
                                    , range = details.range
                                    , attributes = Tuple.second details.value
                                    }
                        in
                        found
                            |> commitText
                            |> addToTextCursor note
                            |> advanceTo details.range.end
                            |> Parser.Loop
            )
            |= withRangeResult
                (attrContainer
                    { attributes = List.filterMap onlyTokens options.inlines
                    , onError = Tolerant.skip
                    }
                )

        -- [Some styled /text/]{token| withAttribtues = True}
        , Parser.succeed
            (\result ->
                case result of
                    Ok details ->
                        let
                            ( noteText, TextCursor childCursor, ( name, attrs ) ) =
                                details.value

                            note =
                                InlineAnnotation
                                    { name = name
                                    , text = noteText
                                    , range = details.range
                                    , attributes = attrs
                                    }
                        in
                        found
                            |> commitText
                            |> addToTextCursor note
                            |> resetBalancedReplacements childCursor.balancedReplacements
                            |> resetTextWith childCursor.current
                            |> advanceTo details.range.end
                            |> Parser.Loop

                    Err errs ->
                        let
                            er =
                                UnexpectedInline
                                    { range = errs.range
                                    , problem =
                                        Error.UnknownInline
                                            (options.inlines
                                                |> List.map inlineExample
                                            )
                                    }
                        in
                        found
                            |> commitText
                            |> addToTextCursor er
                            |> advanceTo errs.range.end
                            |> Parser.Loop
            )
            |= withRangeResult
                (inlineAnnotation options found)
        , -- chomp until a meaningful character
          Parser.succeed
            (\( new, final ) ->
                if new == "" || final then
                    case commitText (addText (String.trimRight new) found) of
                        TextCursor txt ->
                            let
                                styling =
                                    case txt.current of
                                        Text s _ ->
                                            s
                            in
                            -- TODO: What to do on unclosed styling?
                            -- if List.isEmpty styling then
                            Parser.Done (List.reverse txt.found)
                    -- else
                    -- Parser.problem (UnclosedStyles styling)

                else
                    Parser.Loop (addText new found)
            )
            |= (Parser.getChompedString (Parser.chompWhile (\c -> not (List.member c meaningful)))
                    |> Parser.andThen
                        (\str ->
                            Parser.oneOf
                                [ Parser.succeed ( str, True )
                                    |. Parser.token (Parser.Token "\n\n" Newline)
                                , withIndent
                                    (\indentation ->
                                        Parser.succeed
                                            (\finished ->
                                                if finished then
                                                    ( str, True )

                                                else
                                                    ( str ++ "\n", False )
                                            )
                                            |. Parser.token (Parser.Token ("\n" ++ String.repeat indentation " ") Newline)
                                            |= Parser.oneOf
                                                [ Parser.map (always True) (Parser.end End)
                                                , Parser.map (always True) newline
                                                , Parser.succeed False
                                                ]
                                     -- TODO do we need to check that this isn't just a completely blank line?
                                    )
                                , Parser.succeed ( str, True )
                                    |. Parser.token (Parser.Token "\n" Newline)
                                , Parser.succeed ( str, True )
                                    |. Parser.end End
                                , Parser.succeed ( str, False )
                                ]
                        )
               )

        -- |> Parser.andThen
        --     (\new ->
        --     )
        ]


{-| -}
almostReplacement : List Replacement -> TextCursor -> List (Parser Context Problem TextCursor)
almostReplacement replacements existing =
    let
        captureChar char =
            Parser.succeed
                (\c ->
                    addText c existing
                )
                |= Parser.getChompedString
                    (Parser.chompIf (\c -> c == char && char /= '{' && char /= '*' && char /= '/') EscapedChar)

        first repl =
            case repl of
                Replacement x y ->
                    firstChar x

                Balanced range ->
                    firstChar (Tuple.first range.start)

        allFirstChars =
            List.filterMap first replacements
    in
    List.map captureChar allFirstChars



-- inlineAnnotation : () -> () -> Tolerant.Parser Context Problem ( List Text, TextCursor, ( String, List InlineAttribute ) )


inlineAnnotation options found =
    Tolerant.succeed
        (\( text, cursor ) maybeNameAndAttrs ->
            ( text, cursor, maybeNameAndAttrs )
        )
        |> Tolerant.ignore
            (Tolerant.token
                { match = "["
                , problem = InlineStart
                , onError = Tolerant.skip
                }
            )
        |> Tolerant.keep
            (Tolerant.try
                (Parser.loop
                    (textCursor (getCurrentStyles found)
                        { offset = 0
                        , line = 1
                        , column = 1
                        }
                    )
                    (simpleStyledTextTill [ '\n', ']' ] options.replacements)
                )
            )
        |> Tolerant.ignore
            (Tolerant.token
                { match = "]"
                , problem = InlineEnd
                , onError = Tolerant.fastForwardTo [ '}', '\n' ]
                }
            )
        |> Tolerant.keep
            (attrContainer
                { attributes = List.filterMap onlyAnnotations options.inlines
                , onError = Tolerant.fastForwardTo [ '}', '\n' ]
                }
            )


simpleStyledTextTill :
    List Char
    -> List Replacement
    -> TextCursor
    -> Parser Context Problem (Parser.Step TextCursor ( List Text, TextCursor ))
simpleStyledTextTill until replacements cursor =
    -- options meaningful untilStrings found =
    Parser.oneOf
        [ Parser.oneOf (replace replacements cursor)
            |> Parser.map Parser.Loop

        -- If a char matches the first character of a replacement,
        -- but didn't match the full replacement captured above,
        -- then stash that char.
        , Parser.oneOf (almostReplacement replacements cursor)
            |> Parser.map Parser.Loop

        -- Capture style command characters
        , Parser.succeed
            (Parser.Loop << changeStyle cursor)
            |= Parser.oneOf
                [ Parser.map (always Italic) (Parser.token (Parser.Token "/" (Expecting "/")))
                , Parser.map (always Strike) (Parser.token (Parser.Token "~" (Expecting "~")))
                , Parser.map (always Bold) (Parser.token (Parser.Token "*" (Expecting "*")))
                ]
        , -- chomp until a meaningful character
          Parser.chompWhile
            (\c ->
                not (List.member c ('\\' :: '\n' :: until ++ stylingChars ++ replacementStartingChars replacements))
            )
            |> Parser.getChompedString
            |> Parser.andThen
                (\new ->
                    if new == "" || new == "\n" then
                        case commitText cursor of
                            TextCursor txt ->
                                let
                                    styling =
                                        case txt.current of
                                            Text s _ ->
                                                s
                                in
                                Parser.succeed
                                    (Parser.Done
                                        ( List.reverse <| List.filterMap toText txt.found
                                        , TextCursor txt
                                        )
                                    )

                    else
                        Parser.succeed (Parser.Loop (addText new cursor))
                )
        ]


toText textDesc =
    case textDesc of
        Styled _ txt ->
            Just txt

        _ ->
            Nothing


{-| Match one of the attribute containers

    {mytoken| attributeList }
    ^                       ^

Because there is no styled text here, we know the following can't happen:

    1. Change in text styles
    2. Any Replacements

This parser is configureable so that it will either

    fastForward or skip.

If the attributes aren't required (i.e. in a oneOf), then we want to skip to allow testing of other possibilities.

If they are required, then we can fastforward to a specific condition and continue on.

-}
attrContainer :
    { attributes : List ( String, List AttrExpectation )
    , onError : Tolerant.OnError
    }
    -> Tolerant.Parser Context Problem ( String, List InlineAttribute )
attrContainer config =
    Tolerant.succeed identity
        |> Tolerant.ignore
            (Tolerant.token
                { match = "{"
                , problem = InlineStart
                , onError = config.onError
                }
            )
        |> Tolerant.ignore (Tolerant.chompWhile (\c -> c == ' '))
        |> Tolerant.keep
            (Tolerant.oneOf InlineStart
                (List.map tokenBody config.attributes)
            )
        |> Tolerant.ignore (Tolerant.chompWhile (\c -> c == ' '))
        |> Tolerant.ignore
            (Tolerant.token
                { match = "}"
                , problem = InlineEnd
                , onError = Tolerant.fastForwardTo [ '}', '\n' ]
                }
            )


tokenBody : ( String, List AttrExpectation ) -> Tolerant.Parser Context Problem ( String, List InlineAttribute )
tokenBody ( name, attrs ) =
    case attrs of
        [] ->
            Tolerant.map (always ( name, [] )) <|
                Tolerant.keyword
                    { match = name
                    , problem = ExpectingInlineName name
                    , onError = Tolerant.skip
                    }

        _ ->
            Tolerant.succeed (\attributes -> ( name, attributes ))
                |> Tolerant.ignore
                    (Tolerant.keyword
                        { match = name
                        , problem = ExpectingInlineName name
                        , onError = Tolerant.skip
                        }
                    )
                |> Tolerant.ignore (Tolerant.chompWhile (\c -> c == ' '))
                |> Tolerant.ignore
                    (Tolerant.symbol
                        { match = "|"
                        , problem = Expecting "|"
                        , onError = Tolerant.fastForwardTo [ '}', '\n' ]
                        }
                    )
                |> Tolerant.ignore
                    (Tolerant.chompWhile (\c -> c == ' '))
                |> Tolerant.ignore (Tolerant.chompWhile (\c -> c == ' '))
                |> Tolerant.keep
                    (Parser.loop
                        { remaining = attrs
                        , original = attrs
                        , found = []
                        }
                        attributeList
                    )


{-| reorder a list to be in the original order
-}
reorder original current =
    let
        findIndex name exp =
            List.foldl
                (\expectation result ->
                    case result of
                        Err i ->
                            case expectation of
                                ExpectAttrString expName _ ->
                                    if expName == name then
                                        Ok i

                                    else
                                        Err (i + 1)

                                ExpectAttrFloat expName _ ->
                                    if expName == name then
                                        Ok i

                                    else
                                        Err (i + 1)

                                ExpectAttrInt expName _ ->
                                    if expName == name then
                                        Ok i

                                    else
                                        Err (i + 1)

                        Ok i ->
                            Ok i
                )
                (Err 0)
                exp
                |> (\result ->
                        case result of
                            Err i ->
                                i

                            Ok i ->
                                i
                   )
    in
    List.sortBy
        (\attr ->
            case attr of
                AttrString details ->
                    findIndex details.name original

                AttrFloat details ->
                    findIndex details.name original

                AttrInt details ->
                    findIndex details.name original
        )
        current


{-| Parse a set of attributes.

They can be parsed in any order.

-}
attributeList :
    { remaining : List AttrExpectation
    , original : List AttrExpectation
    , found : List InlineAttribute
    }
    ->
        Parser Context
            Problem
            (Parser.Step
                { remaining : List AttrExpectation
                , original : List AttrExpectation
                , found : List InlineAttribute
                }
                (Result (List Problem) (List InlineAttribute))
            )
attributeList cursor =
    case cursor.remaining of
        [] ->
            Parser.succeed (Parser.Done (Ok (reorder cursor.original cursor.found)))

        _ ->
            let
                parseAttr i expectation =
                    Parser.succeed
                        (\attrResult ->
                            case attrResult of
                                Ok attr ->
                                    Parser.Loop
                                        { remaining = removeByIndex i cursor.remaining
                                        , original = cursor.original
                                        , found = attr :: cursor.found
                                        }

                                Err err ->
                                    Parser.Done (Err [ err ])
                        )
                        |= attribute expectation
                        |. (if List.length cursor.remaining > 1 then
                                Parser.succeed ()
                                    |. Parser.chompIf (\c -> c == ',') (Expecting ",")
                                    |. Parser.chompWhile (\c -> c == ' ')

                            else
                                Parser.succeed ()
                           )
            in
            Parser.oneOf
                (List.indexedMap parseAttr cursor.remaining
                    -- TODO: ADD MISSING ATTRIBUTES HERE!!
                    ++ [ Parser.map (always (Parser.Done (Err []))) parseTillEnd ]
                )


attribute : AttrExpectation -> Parser Context Problem (Result Problem InlineAttribute)
attribute attr =
    let
        name =
            case attr of
                ExpectAttrString attrName _ ->
                    attrName

                ExpectAttrFloat attrName _ ->
                    attrName

                ExpectAttrInt attrName _ ->
                    attrName
    in
    Parser.succeed
        (\start equals content end ->
            Result.map
                (\expected ->
                    case expected of
                        ExpectAttrString inlineName value ->
                            AttrString
                                { name = inlineName
                                , range =
                                    { start = start
                                    , end = end
                                    }
                                , value = value
                                }

                        ExpectAttrFloat inlineName value ->
                            AttrFloat
                                { name = inlineName
                                , range =
                                    { start = start
                                    , end = end
                                    }
                                , value = value
                                }

                        ExpectAttrInt inlineName value ->
                            AttrInt
                                { name = inlineName
                                , range =
                                    { start = start
                                    , end = end
                                    }
                                , value = value
                                }
                )
                content
        )
        |= getPosition
        |. Parser.keyword
            (Parser.Token name (ExpectingFieldName name))
        |. Parser.chompWhile (\c -> c == ' ')
        |= Parser.oneOf
            [ Parser.map (always True) (Parser.chompIf (\c -> c == '=') (Expecting "="))
            , Parser.succeed False
            ]
        |. Parser.chompWhile (\c -> c == ' ')
        |= (case attr of
                ExpectAttrString inlineName _ ->
                    Parser.succeed (Ok << ExpectAttrString inlineName)
                        |= Parser.getChompedString
                            (Parser.chompWhile (\c -> c /= '|' && c /= '}' && c /= '\n' && c /= ','))

                ExpectAttrFloat inlineName _ ->
                    Parser.succeed (Result.map (ExpectAttrFloat inlineName))
                        |= floating

                ExpectAttrInt inlineName _ ->
                    Parser.succeed (Result.map (ExpectAttrInt inlineName))
                        |= integer
           )
        |= getPosition



{- Style Helpers -}


changeStyle (TextCursor cursor) styleToken =
    let
        cursorText =
            case cursor.current of
                Text _ txt ->
                    txt

        newText =
            cursor.current
                |> flipStyle styleToken
                |> clearText
    in
    if cursorText == "" then
        TextCursor
            { found = cursor.found
            , current = newText
            , start = cursor.start
            , balancedReplacements = cursor.balancedReplacements
            }

    else
        let
            end =
                measure cursor.start cursorText
        in
        TextCursor
            { found =
                Styled
                    { start = cursor.start
                    , end = end
                    }
                    cursor.current
                    :: cursor.found
            , start = end
            , current = newText
            , balancedReplacements = cursor.balancedReplacements
            }


clearText (Text styles _) =
    Text styles ""


flipStyle newStyle textStyle =
    case textStyle of
        Text styles str ->
            case newStyle of
                Bold ->
                    Text { styles | bold = not styles.bold } str

                Italic ->
                    Text { styles | italic = not styles.italic } str

                Strike ->
                    Text { styles | strike = not styles.strike } str


advanceTo target (TextCursor cursor) =
    TextCursor
        { found = cursor.found
        , current = cursor.current
        , start = target
        , balancedReplacements = cursor.balancedReplacements
        }


getCurrentStyles (TextCursor cursor) =
    getStyles cursor.current


getStyles (Text styles _) =
    styles


measure start textStr =
    let
        len =
            String.length textStr
    in
    { start
        | offset = start.offset + len
        , column = start.column + len
    }


commitText ((TextCursor cursor) as existingTextCursor) =
    case cursor.current of
        Text _ "" ->
            -- nothing to commit
            existingTextCursor

        Text styles cursorText ->
            let
                end =
                    measure cursor.start cursorText
            in
            TextCursor
                { found =
                    Styled
                        { start = cursor.start
                        , end = end
                        }
                        cursor.current
                        :: cursor.found
                , start = end
                , current = Text styles ""
                , balancedReplacements = cursor.balancedReplacements
                }


addToTextCursor new (TextCursor cursor) =
    TextCursor { cursor | found = new :: cursor.found }


resetBalancedReplacements newBalance (TextCursor cursor) =
    TextCursor { cursor | balancedReplacements = newBalance }


resetTextWith (Text styles _) (TextCursor cursor) =
    TextCursor { cursor | current = Text styles "" }



-- |> resetStylesTo cursor.current
{- REPLACEMENT HELPERS -}


{-| **Reclaimed typography**

This function will replace certain characters with improved typographical ones.
Escaping a character will skip the replacement.

    -> "<>" -> a non-breaking space.
        - This can be used to glue words together so that they don't break
        - It also avoids being used for spacing like `&nbsp;` because multiple instances will collapse down to one.
    -> "--" -> "en-dash"
    -> "---" -> "em-dash".
    -> Quotation marks will be replaced with curly quotes.
    -> "..." -> ellipses

-}
replace : List Replacement -> TextCursor -> List (Parser Context Problem TextCursor)
replace replacements existing =
    let
        -- Escaped characters are captured as-is
        escaped =
            Parser.succeed
                (\esc ->
                    addText esc existing
                )
                |. Parser.token
                    (Parser.Token "\\" Escape)
                |= Parser.getChompedString
                    (Parser.chompIf (always True) EscapedChar)

        replaceWith repl =
            case repl of
                Replacement x y ->
                    Parser.succeed
                        (\_ ->
                            addText y existing
                        )
                        |. Parser.token (Parser.Token x (Expecting x))
                        |= Parser.succeed ()

                Balanced range ->
                    let
                        balanceCache =
                            case existing of
                                TextCursor cursor ->
                                    cursor.balancedReplacements

                        id =
                            balanceId range
                    in
                    -- TODO: implement range replacement
                    if List.member id balanceCache then
                        case range.end of
                            ( x, y ) ->
                                Parser.succeed
                                    (addText y existing
                                        |> removeBalance id
                                    )
                                    |. Parser.token (Parser.Token x (Expecting x))

                    else
                        case range.start of
                            ( x, y ) ->
                                Parser.succeed
                                    (addText y existing
                                        |> addBalance id
                                    )
                                    |. Parser.token (Parser.Token x (Expecting x))
    in
    escaped :: List.map replaceWith replacements


balanceId balance =
    let
        join ( x, y ) =
            x ++ y
    in
    join balance.start ++ join balance.end


addBalance id (TextCursor cursor) =
    TextCursor <|
        { cursor | balancedReplacements = id :: cursor.balancedReplacements }


removeBalance id (TextCursor cursor) =
    TextCursor <|
        { cursor | balancedReplacements = List.filter ((/=) id) cursor.balancedReplacements }


addTextToText newString textNodes =
    case textNodes of
        [] ->
            [ Text emptyStyles newString ]

        (Text styles txt) :: remaining ->
            Text styles (txt ++ newString) :: remaining


addText newTxt (TextCursor cursor) =
    case cursor.current of
        Text styles txt ->
            TextCursor { cursor | current = Text styles (txt ++ newTxt) }


stylingChars =
    [ '~'
    , '['
    , '/'
    , '*'
    , '\n'
    , '{'
    , '`'
    ]


firstChar str =
    case String.uncons str of
        Nothing ->
            Nothing

        Just ( fst, _ ) ->
            Just fst


replacementStartingChars replacements =
    let
        first repl =
            case repl of
                Replacement x y ->
                    firstChar x

                Balanced range ->
                    firstChar (Tuple.first range.start)
    in
    List.filterMap first replacements



{- GENERAL HELPERS -}


withIndent fn =
    Parser.getIndent
        |> Parser.andThen fn


withRangeResult :
    Parser Context Problem (Result err thing)
    ->
        Parser Context
            Problem
            (Result
                { range : Range
                , error : err
                }
                { range : Range
                , value : thing
                }
            )
withRangeResult parser =
    Parser.succeed
        (\start result end ->
            case result of
                Ok val ->
                    Ok
                        { range =
                            { start = start
                            , end = end
                            }
                        , value = val
                        }

                Err err ->
                    let
                        range =
                            { start = start
                            , end = end
                            }
                    in
                    Err
                        { range = range
                        , error = err
                        }
        )
        |= getPosition
        |= parser
        |= getPosition


getRangeAndSource :
    Parser Context Problem thing
    ->
        Parser Context
            Problem
            { source : String
            , range : Range
            , value : thing
            }
getRangeAndSource parser =
    Parser.succeed
        (\src start result end ->
            let
                range =
                    { start = start
                    , end = end
                    }
            in
            { range = range
            , value = result
            , source = sliceRange range src
            }
        )
        |= Parser.getSource
        |= getPosition
        |= parser
        |= getPosition


sliceRange range source =
    if range.start.line == range.end.line then
        -- single line
        let
            lineStart =
                range.start.offset - (range.start.column - 1)
        in
        String.slice lineStart (range.end.offset + 20) source
            |> String.lines
            |> List.head
            |> Maybe.withDefault ""

    else
        -- multiline
        let
            snippet =
                String.slice range.start.offset range.end.offset source

            indented =
                String.slice (range.start.offset + 1 - range.start.column)
                    range.start.offset
                    source
        in
        indented ++ snippet


withRange :
    Parser Context Problem thing
    -> Parser Context Problem ( Range, thing )
withRange parser =
    Parser.succeed
        (\start val end ->
            ( { start = start
              , end = end
              }
            , val
            )
        )
        |= getPosition
        |= parser
        |= getPosition


word : Parser Context Problem String
word =
    Parser.chompWhile Char.isAlphaNum
        |> Parser.getChompedString


peek : String -> Parser c p thing -> Parser c p thing
peek name parser =
    Parser.succeed
        (\start val end src ->
            let
                highlightParsed =
                    String.repeat (start.column - 1) " " ++ String.repeat (max 0 (end.column - start.column)) "^"

                fullLine =
                    String.slice (max 0 (start.offset - start.column)) end.offset src

                _ =
                    Debug.log name
                        -- fullLine
                        (String.slice start.offset end.offset src)

                -- _ =
                --     Debug.log name
                --         highlightParsed
            in
            val
        )
        |= getPosition
        |= parser
        |= getPosition
        |= Parser.getSource


getPosition : Parser c p Position
getPosition =
    Parser.succeed
        (\offset ( row, col ) ->
            { offset = offset
            , line = row
            , column = col
            }
        )
        |= Parser.getOffset
        |= Parser.getPosition


parseTillEnd =
    Parser.succeed
        (\str endsWithBracket ->
            endsWithBracket
        )
        |= Parser.chompWhile (\c -> c /= '\n' && c /= '}')
        |= Parser.oneOf
            [ Parser.map (always True) (Parser.token (Parser.Token "}" InlineEnd))
            , Parser.succeed False
            ]



{- MISC HELPERS -}


onlyTokens inline =
    case inline of
        ExpectAnnotation name attrs _ ->
            Nothing

        ExpectToken name attrs ->
            Just ( name, attrs )

        ExpectVerbatim name _ _ ->
            Nothing

        ExpectText _ ->
            Nothing


onlyAnnotations inline =
    case inline of
        ExpectAnnotation name attrs _ ->
            Just ( name, attrs )

        ExpectToken name attrs ->
            Nothing

        ExpectVerbatim name _ _ ->
            Nothing

        ExpectText _ ->
            Nothing


onlyVerbatim inline =
    case inline of
        ExpectAnnotation name attrs _ ->
            Nothing

        ExpectToken name attrs ->
            Nothing

        ExpectVerbatim name attrs _ ->
            Just ( name, attrs )

        ExpectText _ ->
            Nothing


getInlineName inline =
    case inline of
        ExpectAnnotation name attrs _ ->
            name

        ExpectToken name attrs ->
            name

        ExpectVerbatim name _ _ ->
            name

        ExpectText _ ->
            ""


removeByIndex index list =
    List.foldl
        (\item ( cursor, passed ) ->
            if cursor == index then
                ( cursor + 1, passed )

            else
                ( cursor + 1, item :: passed )
        )
        ( 0, [] )
        list
        |> Tuple.second
        |> List.reverse


{-| -}
blocksOrNewlines indentation blocks cursor =
    Parser.oneOf
        [ Parser.end End
            |> Parser.map
                (\_ ->
                    Parser.Done (List.reverse cursor.found)
                )
        , Parser.succeed
            (Parser.Loop
                { parsedSomething = True
                , found = cursor.found
                , seed = cursor.seed
                }
            )
            |. newlineWith "empty Parse.newline"
        , if not cursor.parsedSomething then
            -- First thing already has indentation accounted for.
            makeBlocksParser blocks cursor.seed
                |> Parser.map
                    (\foundBlock ->
                        let
                            ( _, newSeed ) =
                                Id.step cursor.seed
                        in
                        Parser.Loop
                            { parsedSomething = True
                            , found = foundBlock :: cursor.found
                            , seed = newSeed
                            }
                    )

          else
            Parser.oneOf
                [ Parser.succeed
                    (\foundBlock ->
                        let
                            ( _, newSeed ) =
                                Id.step cursor.seed
                        in
                        Parser.Loop
                            { parsedSomething = True
                            , found = foundBlock :: cursor.found
                            , seed = newSeed
                            }
                    )
                    |. Parser.token (Parser.Token (String.repeat indentation " ") (ExpectingIndentation indentation))
                    |= makeBlocksParser blocks cursor.seed
                , Parser.succeed
                    (Parser.Loop
                        { parsedSomething = True
                        , found = cursor.found
                        , seed = cursor.seed
                        }
                    )
                    |. Parser.backtrackable (Parser.chompWhile (\c -> c == ' '))
                    |. Parser.backtrackable newline

                -- We reach here because the indentation parsing was not successful,
                -- meaning the indentation has been lowered and the block is done
                , Parser.succeed (Parser.Done (List.reverse cursor.found))
                ]

        -- Whitespace Line
        , Parser.succeed
            (Parser.Loop
                { parsedSomething = True
                , found = cursor.found
                , seed = cursor.seed
                }
            )
            |. Parser.chompWhile (\c -> c == ' ')
            |. newlineWith "ws-line"
        ]


makeBlocksParser blocks seed =
    let
        gatherParsers myBlock details =
            let
                -- We don't care about the new seed because that's handled by the loop.
                ( _, parser ) =
                    getParserNoBar seed myBlock
            in
            case blockName myBlock of
                Just name ->
                    { blockNames = name :: details.blockNames
                    , childBlocks = Parser.map Ok parser :: details.childBlocks
                    , childValues = details.childValues
                    }

                Nothing ->
                    { blockNames = details.blockNames
                    , childBlocks = details.childBlocks
                    , childValues = Parser.map Ok (withRange parser) :: details.childValues
                    }

        children =
            List.foldl gatherParsers
                { blockNames = []
                , childBlocks = []
                , childValues = []
                }
                blocks

        blockParser =
            Parser.map
                (\( pos, result ) ->
                    Result.map (\desc -> ( pos, desc )) result
                )
                (withRange
                    (Parser.succeed identity
                        |. Parser.token (Parser.Token "|>" BlockStart)
                        |. Parser.chompWhile (\c -> c == ' ')
                        |= Parser.oneOf
                            (List.reverse children.childBlocks
                                ++ [ withIndent
                                        (\indentation ->
                                            Parser.succeed
                                                (\( pos, foundWord ) ->
                                                    Err ( pos, Error.UnknownBlock children.blockNames )
                                                )
                                                |= withRange word
                                                |. newline
                                                |. Parser.loop "" (raggedIndentedStringAbove indentation)
                                        )
                                   ]
                            )
                    )
                )
    in
    Parser.oneOf
        (blockParser
            :: List.reverse children.childValues
        )


type alias NestedIndex =
    { base : Int
    , prev : Int
    }


type alias FlatCursor =
    { icon : Maybe Icon
    , indent : Int
    , content : Description
    }


{-| Results in a flattened version of the parsed list.

    ( 0, Maybe Icon, [ "item one" ] )

    ( 0, Maybe Icon, [ "item two" ] )

    ( 4, Maybe Icon, [ "nested item two", "additional text for nested item two" ] )

    ( 0, Maybe Icon, [ "item three" ] )

    ( 4, Maybe Icon, [ "nested item three" ] )

-}
indentedBlocksOrNewlines :
    Id.Seed
    -> Block thing
    -> ( NestedIndex, List FlatCursor )
    -> Parser Context Problem (Parser.Step ( NestedIndex, List FlatCursor ) (List FlatCursor))
indentedBlocksOrNewlines seed item ( indentation, existing ) =
    Parser.oneOf
        [ Parser.end End
            |> Parser.map
                (\_ ->
                    Parser.Done (List.reverse existing)
                )

        -- Whitespace Line
        , skipBlankLineWith (Parser.Loop ( indentation, existing ))
        , Parser.oneOf
            [ -- block with required indent
              expectIndentation indentation.base indentation.prev
                |> Parser.andThen
                    (\newIndent ->
                        let
                            ( itemSeed, itemParser ) =
                                getParser seed item
                        in
                        -- If the indent has changed, then the delimiter is required
                        Parser.withIndent newIndent <|
                            Parser.oneOf
                                ((Parser.succeed
                                    (\iconResult itemResult ->
                                        let
                                            newIndex =
                                                { prev = newIndent
                                                , base = indentation.base
                                                }
                                        in
                                        Parser.Loop
                                            ( newIndex
                                            , { indent = newIndent
                                              , icon = Just iconResult
                                              , content = itemResult
                                              }
                                                :: existing
                                            )
                                    )
                                    |= iconParser
                                    |= itemParser
                                 )
                                    :: (if newIndent - 4 == indentation.prev then
                                            [ itemParser
                                                |> Parser.map
                                                    (\foundBlock ->
                                                        let
                                                            newIndex =
                                                                { prev = indentation.prev
                                                                , base = indentation.base
                                                                }
                                                        in
                                                        Parser.Loop
                                                            ( newIndex
                                                            , { indent = indentation.prev
                                                              , icon = Nothing
                                                              , content = foundBlock
                                                              }
                                                                :: existing
                                                            )
                                                    )
                                            ]

                                        else
                                            []
                                       )
                                )
                    )

            -- We reach here because the indentation parsing was not successful,
            -- This means any issues are handled by whatever parser comes next.
            , Parser.succeed (Parser.Done (List.reverse existing))
            ]
        ]


{-| We only expect nearby indentations.

We can't go below the `base` indentation.

Based on the previous indentation:

  - previous - 4
  - previous
  - previous + 4

If we don't match the above rules, we might want to count the mismatched number.

-}
expectIndentation : Int -> Int -> Parser Context Problem Int
expectIndentation base previous =
    Parser.succeed Tuple.pair
        |= Parser.oneOf
            ([ Parser.succeed (previous + 4)
                |. Parser.token (Parser.Token (String.repeat (previous + 4) " ") (ExpectingIndentation (previous + 4)))
             , Parser.succeed previous
                |. Parser.token (Parser.Token (String.repeat previous " ") (ExpectingIndentation previous))
             ]
                ++ descending base previous
            )
        |= Parser.getChompedString (Parser.chompWhile (\c -> c == ' '))
        |> Parser.andThen
            (\( indentLevel, extraSpaces ) ->
                if extraSpaces == "" then
                    Parser.succeed indentLevel

                else
                    Parser.problem
                        (ExpectingIndentation (base + indentLevel))
            )


iconParser =
    Parser.oneOf
        [ Parser.succeed Bullet
            |. Parser.chompIf (\c -> c == '-') (Expecting "-")
            |. Parser.chompWhile (\c -> c == '-' || c == ' ')
        , Parser.succeed AutoNumber
            |. Parser.chompIf (\c -> c == '#') (Expecting "#")
            |. Parser.chompWhile (\c -> c == '.' || c == ' ')
        ]


skipBlankLineWith : thing -> Parser Context Problem thing
skipBlankLineWith x =
    Parser.succeed x
        |. Parser.token (Parser.Token "\n" Newline)
        |. Parser.oneOf
            [ Parser.succeed ()
                |. Parser.backtrackable (Parser.chompWhile (\c -> c == ' '))
                |. Parser.backtrackable (Parser.token (Parser.Token "\n" Newline))
            , Parser.succeed ()
            ]


{-| Parse all indentation levels between `prev` and `base` in increments of 4.
-}
descending : Int -> Int -> List (Parser Context Problem Int)
descending base prev =
    if prev <= base then
        []

    else
        List.reverse
            (List.map
                (\x ->
                    let
                        level =
                            base + (x * 4)
                    in
                    Parser.succeed level
                        |. Parser.token (Parser.Token (String.repeat level " ") (ExpectingIndentation level))
                )
                (List.range 0 (((prev - 4) - base) // 4))
            )


buildTree : Int -> List FlatCursor -> List (Nested Description)
buildTree baseIndent items =
    let
        -- gather ( indentation, icon, item ) (TreeBuilder builder) =
        gather item builder =
            addItem (item.indent - baseIndent) item.icon item.content builder

        groupByIcon item maybeCursor =
            case maybeCursor of
                Nothing ->
                    case item.icon of
                        Just icon ->
                            Just
                                { indent = item.indent
                                , icon = icon
                                , items = [ item.content ]
                                , accumulated = []
                                }

                        Nothing ->
                            -- Because of how the code runs, we have a tenuous guarantee that this branch won't execute.
                            -- Not entirely sure how to make the types work to eliminate this.
                            Nothing

                Just cursor ->
                    Just <|
                        case item.icon of
                            Nothing ->
                                { indent = cursor.indent
                                , icon = cursor.icon
                                , items = item.content :: cursor.items
                                , accumulated = cursor.accumulated
                                }

                            Just icon ->
                                { indent = item.indent
                                , icon = icon
                                , items = [ item.content ]
                                , accumulated =
                                    { indent = cursor.indent
                                    , icon = cursor.icon
                                    , content = cursor.items
                                    }
                                        :: cursor.accumulated
                                }

        finalizeGrouping maybeCursor =
            case maybeCursor of
                Nothing ->
                    []

                Just cursor ->
                    case cursor.items of
                        [] ->
                            cursor.accumulated

                        _ ->
                            { indent = cursor.indent
                            , icon = cursor.icon
                            , content = cursor.items
                            }
                                :: cursor.accumulated

        newTree =
            items
                |> List.foldl groupByIcon Nothing
                |> finalizeGrouping
                |> List.reverse
                |> List.foldl gather emptyTreeBuilder
    in
    case newTree of
        TreeBuilder builder ->
            List.reverse (renderLevels builder.levels)


{-| A list item started with a list icon.

If indent stays the same
-> add to items at the current stack

if ident increases
-> create a new level in the stack

if ident decreases
-> close previous group
->

    1 Icon
        1.1 Content
        1.2 Icon
        1.3 Icon
           1.3.1 Icon

        1.4

    2 Icon

    Steps =
    []

    [ Level [ Item 1. [] ]
    ]

    [ Level [ Item 1.1 ]
    , Level [ Item 1. [] ]
    ]

    [ Level [ Item 1.2, Item 1.1 ]
    , Level [ Item 1. [] ]
    ]

    [ Level [ Item 1.3, Item 1.2, Item 1.1 ]
    , Level [ Item 1. [] ]
    ]

    [ Level [ Item 1.3.1 ]
    , Level [ Item 1.3, Item 1.2, Item 1.1 ]
    , Level [ Item 1. [] ]
    ]


    [ Level [ Item 1.4, Item 1.3([ Item 1.3.1 ]), Item 1.2, Item 1.1 ]
    , Level [ Item 1. [] ]
    ]

    [ Level [ Item 2., Item 1. (Level [ Item 1.4, Item 1.3([ Item 1.3.1 ]), Item 1.2, Item 1.1 ]) ]
    ]

-}
addItem : Int -> Icon -> List Description -> TreeBuilder -> TreeBuilder
addItem indentation icon content (TreeBuilder builder) =
    let
        newItem : Nested Description
        newItem =
            Nested
                { icon = icon
                , children = []
                , content = content
                }
    in
    case builder.levels of
        [] ->
            TreeBuilder
                { previousIndent = indentation
                , levels =
                    [ newItem ]
                }

        lvl :: remaining ->
            if indentation == 0 then
                -- add to current level
                TreeBuilder
                    { previousIndent = indentation
                    , levels =
                        newItem :: lvl :: remaining
                    }

            else
                -- We've dedented, so we need to first collapse the current level
                -- into the one below, then add an item to that level
                TreeBuilder
                    { previousIndent = indentation
                    , levels =
                        addToLevel
                            ((abs indentation // 4) - 1)
                            newItem
                            lvl
                            :: remaining
                    }



-- indentIndex (Nested nested) =
--     Nested
--         { nested
--             | index = 1 :: nested.index
--         }
-- indexTo i (Nested nested) =
--     case nested.index of
--         [] ->
--             Nested { nested | index = [ i ] }
--         top :: tail ->
--             Nested { nested | index = i :: tail }


addToLevel index brandNewItem (Nested parent) =
    if index <= 0 then
        Nested
            { parent
                | children =
                    brandNewItem
                        :: parent.children
            }

    else
        case parent.children of
            [] ->
                Nested parent

            top :: remain ->
                Nested
                    { parent
                        | children =
                            addToLevel (index - 1) brandNewItem top
                                :: remain
                    }


addToChildren : Nested Description -> Nested Description -> Nested Description
addToChildren child (Nested parent) =
    Nested { parent | children = child :: parent.children }



{- NESTED LIST HELPERS -}
{- Nested Lists -}


{-| = indentLevel icon space content
| indentLevel content

Where the second variation can only occur if the indentation is larger than the previous one.

A list item started with a list icon.

    If indent stays the same
    -> add to items at the current stack

    if ident increases
    -> create a new level in the stack

    if ident decreases
    -> close previous group
    ->

    <list>
        <*item>
            <txt> -> add to head sections
            <txt> -> add to head sections
            <item> -> add to head sections
            <item> -> add to head sections
                <txt> -> add to content
                <txt> -> add to content
                <item> -> add to content
                <item> -> add to content
            <item> -> add to content

        <*item>
        <*item>

    Section
        [ IconSection
            { icon = *
            , sections =
                [ Text
                , Text
                , IconSection Text
                , IconSection
                    [ Text
                    , Text
                    , item
                    , item
                    ]
                ]
            }
        , Icon -> Content
        , Icon -> Content
        ]

-}
type TreeBuilder
    = TreeBuilder
        { previousIndent : Int
        , levels :
            -- (mostRecent :: remaining)
            List (Nested Description)
        }


emptyTreeBuilder : TreeBuilder
emptyTreeBuilder =
    TreeBuilder
        { previousIndent = 0
        , levels = []
        }


renderLevels : List (Nested Description) -> List (Nested Description)
renderLevels levels =
    case levels of
        [] ->
            []

        _ ->
            List.indexedMap
                (\index level ->
                    reverseTree { index = index, level = [] } level
                )
                levels


reverseTree cursor (Nested nest) =
    Nested
        { icon = nest.icon
        , content = List.reverse nest.content
        , children =
            List.foldl rev ( dive cursor, [] ) nest.children
                |> Tuple.second
        }


rev nest ( cursor, found ) =
    ( next cursor, reverseTree cursor nest :: found )


type alias TreeIndex =
    { index : Int
    , level : List Int
    }


dive cursor =
    { cursor
        | index = 0
        , level = cursor.index :: cursor.level
    }


next cursor =
    { cursor
        | index = cursor.index + 1
    }
