//
//  iTermTextExtractor.m
//  iTerm
//
//  Created by George Nachman on 2/17/14.
//
//

#import "iTermTextExtractor.h"
#import "DebugLogging.h"
#import "iTermPreferences.h"
#import "NSStringITerm.h"
#import "NSMutableAttributedString+iTerm.h"
#import "RegexKitLite.h"
#import "PreferencePanel.h"
#import "SmartMatch.h"
#import "SmartSelectionController.h"

// Must find at least this many divider chars in a row for it to count as a divider.
static const int kNumCharsToSearchForDivider = 8;

@implementation iTermTextExtractor {
    id<PTYTextViewDataSource> _dataSource;
    VT100GridRange _logicalWindow;
}

+ (instancetype)textExtractorWithDataSource:(id<PTYTextViewDataSource>)dataSource {
    return [[[self alloc] initWithDataSource:dataSource] autorelease];
}

+ (NSCharacterSet *)wordSeparatorCharacterSet
{
    NSMutableCharacterSet *charset = [[[NSMutableCharacterSet alloc] init] autorelease];
    [charset formUnionWithCharacterSet:[NSCharacterSet whitespaceCharacterSet]];
    
    NSMutableCharacterSet *complement = [[[NSMutableCharacterSet alloc] init] autorelease];
    [complement formUnionWithCharacterSet:[NSCharacterSet alphanumericCharacterSet]];
    [complement addCharactersInString:[iTermPreferences stringForKey:kPreferenceKeyCharactersConsideredPartOfAWordForSelection]];
    [complement addCharactersInRange:NSMakeRange(DWC_RIGHT, 1)];
    [complement addCharactersInRange:NSMakeRange(DWC_SKIP, 1)];
    [charset formUnionWithCharacterSet:[complement invertedSet]];
    
    return charset;
}

- (id)initWithDataSource:(id<PTYTextViewDataSource>)dataSource {
    self = [super init];
    if (self) {
        _dataSource = dataSource;
        _logicalWindow = VT100GridRangeMake(0, [dataSource width]);
    }
    return self;
}

- (BOOL)hasLogicalWindow {
    return !(_logicalWindow.location == 0 && [self xLimit] == [_dataSource width]);
}

- (void)restrictToLogicalWindowIncludingCoord:(VT100GridCoord)coord {
    NSIndexSet *possibleDividers = [self possibleColumnDividerIndexesAround:coord];
    __block int dividerBefore = 0;
    __block int dividerAfter = -1;
    [possibleDividers enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if ([self coordContainsColumnDivider:VT100GridCoordMake(idx, coord.y)]) {
            if (idx < coord.x && idx > dividerBefore) {
                dividerBefore = (int)idx + 1;
            } else if (idx > coord.x) {
                dividerAfter = (int)idx;
                *stop = YES;
            }
        }
    }];
    if (dividerAfter == -1) {
        dividerAfter = [_dataSource width];
    }
    _logicalWindow.location = dividerBefore;
    _logicalWindow.length = dividerAfter - dividerBefore;
}

- (VT100GridWindowedRange)rangeForWordAt:(VT100GridCoord)location {
    location = [self coordLockedToWindow:location];
    iTermTextExtractorClass theClass =
        [self classForCharacter:[self characterAt:location]];
    if (theClass == kTextExtractorClassOther) {
        return [self windowedRangeWithRange:VT100GridCoordRangeMake(location.x,
                                                                    location.y,
                                                                    location.x + 1,
                                                                    location.y)];
    }
    const int xLimit = [self xLimit];
    const int width = [_dataSource width];
    const BOOL windowTouchesLeftMargin = (_logicalWindow.location == 0);
    const BOOL windowTouchesRightMargin = (xLimit == width);
    VT100GridCoordRange theRange = VT100GridCoordRangeMake(location.x,
                                                           location.y,
                                                           width,
                                                           [_dataSource numberOfLines] - 1);
    // Search forward for the end of the word.
    __block VT100GridCoord end = location;
    [self enumerateCharsInRange:VT100GridWindowedRangeMake(theRange,
                                                           _logicalWindow.location,
                                                           _logicalWindow.length)
                      charBlock:^BOOL(screen_char_t theChar, VT100GridCoord coord) {
                          BOOL isInWord = ([self classForCharacter:theChar] == theClass);
                          if (isInWord) {
                              end = coord;
                          }
                          return !isInWord;
                      }
                       eolBlock:^BOOL(unichar code, int numPreceedingNulls, int line) {
                           return [self shouldStopEnumeratingWithCode:code
                                                             numNulls:numPreceedingNulls
                                              windowTouchesLeftMargin:windowTouchesLeftMargin
                                             windowTouchesRightMargin:windowTouchesRightMargin
                                                     ignoringNewlines:NO];
                       }];

    // Search backward for the start of the word.
    theRange = VT100GridCoordRangeMake(0, 0, location.x, location.y);
    __block VT100GridCoord start = location;
    [self enumerateInReverseCharsInRange:VT100GridWindowedRangeMake(theRange,
                                                                    _logicalWindow.location,
                                                                    _logicalWindow.length)
                               charBlock:^BOOL(screen_char_t theChar, VT100GridCoord coord) {
                                   BOOL isInWord = ([self classForCharacter:theChar] == theClass);
                                   if (isInWord) {
                                       start = coord;
                                   }
                                   return !isInWord;
                               }
                                eolBlock:^BOOL(unichar code, int numPreceedingNulls, int line) {
                                    return [self shouldStopEnumeratingWithCode:code
                                                                      numNulls:numPreceedingNulls
                                                       windowTouchesLeftMargin:windowTouchesLeftMargin
                                                      windowTouchesRightMargin:windowTouchesRightMargin
                                                              ignoringNewlines:NO];

                                }];
    
    return [self windowedRangeWithRange:VT100GridCoordRangeMake(start.x,
                                                                start.y,
                                                                end.x + 1,
                                                                end.y)];
}

- (NSString *)stringForCharacter:(screen_char_t)theChar {
    unichar temp[kMaxParts];
    int length = ExpandScreenChar(&theChar, temp);
    return [NSString stringWithCharacters:temp length:length];
}

- (NSString *)stringForCharacterAt:(VT100GridCoord)location {
    screen_char_t *theLine = [_dataSource getLineAtIndex:location.y];
    unichar temp[kMaxParts];
    int length = ExpandScreenChar(theLine + location.x, temp);
    return [NSString stringWithCharacters:temp length:length];
}

- (NSDictionary *)smartSelectionAt:(VT100GridCoord)location
                         withRules:(NSArray *)rules
                    actionRequired:(BOOL)actionRequired
                             range:(VT100GridWindowedRange *)range
                  ignoringNewlines:(BOOL)ignoringNewlines {
    location = [self coordLockedToWindow:location];
    int targetOffset;
    const int numLines = 2;
    NSMutableArray* coords = [NSMutableArray arrayWithCapacity:numLines * _logicalWindow.length];
    NSString *textWindow = [self textAround:location
                                     radius:2
                               targetOffset:&targetOffset
                                     coords:coords
                           ignoringNewlines:ignoringNewlines || [self hasLogicalWindow]];

    NSArray* rulesArray = rules ?: [SmartSelectionController defaultRules];
    const int numRules = [rulesArray count];

    NSMutableDictionary* matches = [NSMutableDictionary dictionaryWithCapacity:13];
    int numCoords = [coords count];
    
    BOOL debug = [SmartSelectionController logDebugInfo];
    if (debug) {
        NSLog(@"Perform smart selection on text: %@", textWindow);
    }
    for (int j = 0; j < numRules; j++) {
        NSDictionary *rule = [rulesArray objectAtIndex:j];
        if (actionRequired && [[SmartSelectionController actionsInRule:rule] count] == 0) {
            DLog(@"Ignore smart selection rule because it has no action: %@", rule);
            continue;
        }
        NSString *regex = [SmartSelectionController regexInRule:rule];
        double precision = [SmartSelectionController precisionInRule:rule];
        if (debug) {
            NSLog(@"Try regex %@", regex);
        }
        for (int i = 0; i <= targetOffset; i++) {
            NSString* substring = [textWindow substringWithRange:NSMakeRange(i, [textWindow length] - i)];
            NSError* regexError = nil;
            NSRange temp = [substring rangeOfRegex:regex
                                           options:0
                                           inRange:NSMakeRange(0, [substring length])
                                           capture:0
                                             error:&regexError];
            if (temp.location != NSNotFound) {
                if (i + temp.location <= targetOffset && i + temp.location + temp.length > targetOffset) {
                    NSString* result = [substring substringWithRange:temp];
                    double score = precision * (double) temp.length;
                    SmartMatch* oldMatch = [matches objectForKey:result];
                    if (!oldMatch || score > oldMatch.score) {
                        SmartMatch* match = [[[SmartMatch alloc] init] autorelease];
                        match.score = score;
                        VT100GridCoord startCoord = [coords[i + temp.location] gridCoordValue];
                        VT100GridCoord endCoord = [coords[MIN(numCoords - 1,
                                                              i + temp.location + temp.length - 1)] gridCoordValue];
                        endCoord = [self successorOfCoord:endCoord];
                        match.startX = startCoord.x;
                        match.absStartY = startCoord.y + [_dataSource totalScrollbackOverflow];
                        match.endX = endCoord.x;
                        match.absEndY = endCoord.y + [_dataSource totalScrollbackOverflow];
                        match.rule = rule;
                        [matches setObject:match forKey:result];
                        
                        if (debug) {
                            NSLog(@"Add result %@ at %d,%lld -> %d,%lld with score %lf", result,
                                  match.startX, match.absStartY, match.endX, match.absEndY,
                                  match.score);
                        }
                    }
                    i += temp.location + temp.length - 1;
                } else {
                    i += temp.location;
                }
            } else {
                break;
            }
        }
    }
    
    if ([matches count]) {
        NSArray* sortedMatches = [[matches allValues] sortedArrayUsingSelector:@selector(compare:)];
        SmartMatch* bestMatch = [sortedMatches lastObject];
        if (debug) {
            NSLog(@"Select match with score %lf", bestMatch.score);
        }
        VT100GridCoordRange theRange =
            VT100GridCoordRangeMake(bestMatch.startX,
                                    bestMatch.absStartY - [_dataSource totalScrollbackOverflow],
                                    bestMatch.endX,
                                    bestMatch.absEndY - [_dataSource totalScrollbackOverflow]);
        *range = [self windowedRangeWithRange:theRange];
        return bestMatch.rule;
    } else {
        if (debug) {
            NSLog(@"No matches. Fall back on word selection.");
        }
        // Fall back on word selection
        *range = [self rangeForWordAt:location];
        return nil;
    }
}

// Returns the class for a character.
- (iTermTextExtractorClass)classForCharacter:(screen_char_t)theCharacter {
    if (theCharacter.code == TAB_FILLER && !theCharacter.complexChar) {
        return kTextExtractorClassWhitespace;
    }

    if (!theCharacter.code) {
        return kTextExtractorClassNull;
    }
    
    NSString *asString = [self stringForCharacter:theCharacter];
    NSRange range;
    range = [asString rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
    if (range.length == asString.length) {
        return kTextExtractorClassWhitespace;
    }
    
    range = [asString rangeOfCharacterFromSet:[NSCharacterSet alphanumericCharacterSet]];
    if (range.length == asString.length) {
        return kTextExtractorClassWord;
    }
    
    range = [[iTermPreferences stringForKey:kPreferenceKeyCharactersConsideredPartOfAWordForSelection]
                rangeOfString:asString];
    if (range.length == asString.length) {
        return kTextExtractorClassWord;
    }
    
    return kTextExtractorClassOther;
}

- (VT100GridWindowedRange)rangeOfParentheticalSubstringAtLocation:(VT100GridCoord)location {
    NSString *paren = [self stringForCharacterAt:location];
    NSDictionary *forwardMatches = @{ @"(": @")",
                                      @"[": @"]",
                                      @"{": @"}" };
    NSString *match = nil;
    BOOL forward;
    for (NSString *open in forwardMatches) {
        NSString *close = forwardMatches[open];
        if ([paren isEqualToString:open]) {
            match = close;
            forward = YES;
            break;
        }
        if ([paren isEqualToString:close]) {
            match = open;
            forward = NO;
            break;
        }
    }
    if (!match) {
        return [self windowedRangeWithRange:VT100GridCoordRangeMake(-1, -1, -1, -1)];
    }
    
    __block int level = 0;
    __block int left = 10000;
    VT100GridCoord end = [self searchFrom:location
                                  forward:forward
                             forCharacterMatchingFilter:^BOOL (screen_char_t theChar,
                                                               VT100GridCoord coord) {
                                 if (--left == 0) {
                                     return YES;
                                 }
                                 NSString *string = [self stringForCharacter:theChar];
                                 if ([string isEqualToString:match]) {
                                     level--;
                                 } else if ([string isEqualToString:paren]) {
                                     level++;
                                 }
                                 return level == 0;
                             }];
    if (left == 0) {
        return [self windowedRangeWithRange:VT100GridCoordRangeMake(-1, -1, -1, -1)];
    } else if (forward) {
        return [self windowedRangeWithRange:VT100GridCoordRangeMake(location.x,
                                                                    location.y,
                                                                    end.x + 1,
                                                                    end.y)];
    } else {
        return [self windowedRangeWithRange:VT100GridCoordRangeMake(end.x,
                                                                    end.y,
                                                                    location.x + 1,
                                                                    location.y)];
    }
}

- (VT100GridCoord)successorOfCoord:(VT100GridCoord)coord {
    coord.x++;
    int xLimit = [self xLimit];
    if (coord.x >= xLimit) {
        coord.x = _logicalWindow.location;
        coord.y++;
        if (coord.y >= [_dataSource numberOfLines]) {
            return VT100GridCoordMake(xLimit - 1, [_dataSource numberOfLines] - 1);
        }
    }
    return coord;
}

- (VT100GridCoord)predecessorOfCoord:(VT100GridCoord)coord {
    coord.x--;
    if (coord.x < _logicalWindow.location) {
        coord.x = [self xLimit] - 1;
        coord.y--;
        if (coord.y < 0) {
            return VT100GridCoordMake(_logicalWindow.location, 0);
        }
    }
    return coord;
}

- (VT100GridCoord)coord:(VT100GridCoord)coord plus:(int)n {
    int left = _logicalWindow.length >= 0 ? _logicalWindow.location : 0;
    int right = [self xLimit];
    int span = right - left;
    
    // Advance it by n.
    coord.x += n;
    
    // If n was negative, move it right and up until it's legal.
    while (coord.x < left) {
        coord.y--;
        coord.x += span;
    }
    
    // If n was positive, move it left and down until it's legal.
    while (coord.x >= right) {
        coord.x -= span;
        coord.y++;
    }
    
    // Make sure y value is legit.
    coord.y = MAX(0, MIN([_dataSource numberOfLines] - 1, coord.y));

    return coord;
}

- (VT100GridCoord)searchFrom:(VT100GridCoord)start
                     forward:(BOOL)forward
  forCharacterMatchingFilter:(BOOL (^)(screen_char_t, VT100GridCoord))block {
    VT100GridCoord coord = start;
    screen_char_t *theLine;
    int y = coord.y;
    theLine = [_dataSource getLineAtIndex:coord.y];
    while (1) {
        if (y != coord.y) {
            theLine = [_dataSource getLineAtIndex:coord.y];
            y = coord.y;
        }
        BOOL stop = block(theLine[coord.x], coord);
        if (stop) {
            return coord;
        }
        VT100GridCoord prev = coord;
        if (forward) {
            coord = [self successorOfCoord:coord];
        } else {
            coord = [self predecessorOfCoord:coord];
        }
        if (VT100GridCoordEquals(coord, prev)) {
            return VT100GridCoordMake(-1, -1);
        }
    }
}

- (BOOL)shouldStopEnumeratingWithCode:(unichar)code
                             numNulls:(int)numNulls
              windowTouchesLeftMargin:(BOOL)windowTouchesLeftMargin
             windowTouchesRightMargin:(BOOL)windowTouchesRightMargin
                     ignoringNewlines:(BOOL)ignoringNewlines {
    if (windowTouchesRightMargin && windowTouchesLeftMargin) {
        return numNulls || (code == EOL_HARD && !ignoringNewlines);
    } else {
        return numNulls > 0;
    }
}

- (NSString *)textAround:(VT100GridCoord)coord
                  radius:(int)radius
            targetOffset:(int *)targetOffset
                  coords:(NSMutableArray *)coords
        ignoringNewlines:(BOOL)ignoringNewlines {
    int xLimit = [self xLimit];
    int trueWidth = [_dataSource width];
    VT100GridCoordRange theRange = VT100GridCoordRangeMake(0,
                                                           coord.y - radius,
                                                           coord.x,
                                                           coord.y);
    NSMutableString* joinedLines =
        [NSMutableString stringWithCapacity:radius * _logicalWindow.length];
    VT100GridWindowedRange windowedRange = VT100GridWindowedRangeMake(theRange,
                                                                      _logicalWindow.location,
                                                                      _logicalWindow.length);
    [self enumerateInReverseCharsInRange:windowedRange
                               charBlock:^BOOL(screen_char_t theChar, VT100GridCoord charCoord) {
                                   if (!theChar.code) {
                                       return YES;
                                   }
                                   NSString* string = CharToStr(theChar.code, theChar.complexChar);
                                   [joinedLines insertString:string atIndex:0];
                                   for (int i = 0; i < [string length]; i++) {
                                     [coords insertObject:[NSValue valueWithGridCoord:charCoord] atIndex:0];
                                   }
                                   return NO;
                               }
                                eolBlock:^BOOL(unichar code, int numPreceedingNulls, int line) {
                                    return [self shouldStopEnumeratingWithCode:code
                                                                      numNulls:numPreceedingNulls
                                                       windowTouchesLeftMargin:(_logicalWindow.location == 0)
                                                      windowTouchesRightMargin:xLimit == trueWidth
                                                              ignoringNewlines:ignoringNewlines];
                                }];

    theRange = VT100GridCoordRangeMake(coord.x,
                                       coord.y,
                                       [_dataSource width],
                                       coord.y + radius);
    windowedRange = VT100GridWindowedRangeMake(theRange,
                                               _logicalWindow.location,
                                               _logicalWindow.length);

    [self enumerateCharsInRange:windowedRange
                      charBlock:^BOOL(screen_char_t theChar, VT100GridCoord charCoord) {
                          if (!theChar.code) {
                              return YES;
                          }
                          NSString* string = CharToStr(theChar.code, theChar.complexChar);
                          [joinedLines appendString:string];
                          for (int i = 0; i < [string length]; i++) {
                              [coords addObject:[NSValue valueWithGridCoord:charCoord]];
                          }
                          return NO;
                      }
                       eolBlock:^BOOL(unichar code, int numPreceedingNulls, int line) {
                           return [self shouldStopEnumeratingWithCode:code
                                                             numNulls:numPreceedingNulls
                                              windowTouchesLeftMargin:(_logicalWindow.location == 0)
                                             windowTouchesRightMargin:xLimit == trueWidth
                                                     ignoringNewlines:ignoringNewlines];
                       }];

    *targetOffset = -1;
    for (int i = 0; i < coords.count; i++) {
        NSComparisonResult order = VT100GridCoordOrder(coord, [coords[i] gridCoordValue]);
        if (order != NSOrderedDescending) {
            *targetOffset = i;
            break;
        }
    }
    if (*targetOffset == -1) {
        NSLog(@"Didn't find coord!");
    }
    return joinedLines;
}

- (VT100GridWindowedRange)rangeForWrappedLineEncompassing:(VT100GridCoord)coord
                                     respectContinuations:(BOOL)respectContinuations {
    int start = [self lineNumberWithStartOfWholeLineIncludingLine:coord.y
                                             respectContinuations:respectContinuations];
    int end = [self lineNumberWithEndOfWholeLineIncludingLine:coord.y
                                             respectContinuations:respectContinuations];
    return [self windowedRangeWithRange:VT100GridCoordRangeMake(_logicalWindow.location,
                                                                start,
                                                                [self xLimit],
                                                                end)];
}

- (NSString *)contentInRange:(VT100GridWindowedRange)windowedRange
                  nullPolicy:(iTermTextExtractorNullPolicy)nullPolicy
                         pad:(BOOL)pad
          includeLastNewline:(BOOL)includeLastNewline
      trimTrailingWhitespace:(BOOL)trimSelectionTrailingSpaces
                cappedAtSize:(int)maxBytes
{
    DLog(@"Find selected text in range %@ pad=%d, includeLastNewline=%d, trim=%d",
         VT100GridWindowedRangeDescription(windowedRange), (int)pad, (int)includeLastNewline,
         (int)trimSelectionTrailingSpaces);
    NSMutableString* result = [NSMutableString string];
    if (maxBytes < 0) {
        maxBytes = INT_MAX;
    }
    [self enumerateCharsInRange:windowedRange
                      charBlock:^BOOL(screen_char_t theChar, VT100GridCoord coord) {
                          if (theChar.code == TAB_FILLER) {
                              // Convert orphan tab fillers (those without a subsequent
                              // tab character) into spaces.
                              if ([self isTabFillerOrphanAt:coord]) {
                                  [result appendString:@" "];
                              }
                          } else if (theChar.code == 0 && !theChar.complexChar) {
                              // This is only reached for midline nulls; nulls at the end of the
                              // line end up in eolBlock.
                              switch (nullPolicy) {
                                  case kiTermTextExtractorNullPolicyFromLastToEnd:
                                      [result deleteCharactersInRange:NSMakeRange(0, result.length)];
                                      break;
                                  case kiTermTextExtractorNullPolicyFromStartToFirst:
                                      return YES;
                                  case kiTermTextExtractorNullPolicyTreatAsSpace:
                                  case kiTermTextExtractorNullPolicyMidlineAsSpaceIgnoreTerminal:
                                      [result appendString:@" "];
                                      break;
                              }
                          } else if (theChar.code != DWC_RIGHT &&
                                     theChar.code != DWC_SKIP) {
                              // Normal character
                              [result appendString:ScreenCharToStr(&theChar)];
                          }
                          return [result length] >= maxBytes;
                      }
                       eolBlock:^BOOL(unichar code, int numPreceedingNulls, int line) {
                               // If there is no text after this, insert a hard line break.
                               if (pad) {
                                   for (int i = 0; i < numPreceedingNulls; i++) {
                                       [result appendString:@" "];
                                   }
                               } else if (numPreceedingNulls > 0) {
                                   switch (nullPolicy) {
                                       case kiTermTextExtractorNullPolicyFromLastToEnd:
                                           [result deleteCharactersInRange:NSMakeRange(0, result.length)];
                                           break;
                                       case kiTermTextExtractorNullPolicyFromStartToFirst:
                                           return YES;
                                       case kiTermTextExtractorNullPolicyTreatAsSpace:
                                           [result appendString:@" "];
                                           break;
                                       case kiTermTextExtractorNullPolicyMidlineAsSpaceIgnoreTerminal:
                                           break;
                                   }
                               }
                               if (code == EOL_HARD &&
                                   (includeLastNewline || line < windowedRange.coordRange.end.y)) {
                                   if (trimSelectionTrailingSpaces) {
                                       [result trimTrailingWhitespace];
                                   }
                                   [result appendString:@"\n"];
                               }
                               return [result length] >= maxBytes;
                           }];
    
    if (trimSelectionTrailingSpaces) {
        return [result stringByTrimmingTrailingWhitespace];
    } else {
        return result;
    }
}


- (NSAttributedString *)attributedContentInRange:(VT100GridWindowedRange)range
                                             pad:(BOOL)pad
                               attributeProvider:(NSDictionary *(^)(screen_char_t))attributeProvider
{
    NSMutableAttributedString* result = [[[NSMutableAttributedString alloc] init] autorelease];
    [self enumerateCharsInRange:range
                      charBlock:^BOOL(screen_char_t theChar, VT100GridCoord coord) {
                          if (theChar.code == 0 && !theChar.complexChar) {
                              [result iterm_appendString:@" "];
                          } else if (theChar.code == TAB_FILLER) {
                              // Convert orphan tab fillers (those without a subsequent
                              // tab character) into spaces.
                              if ([self isTabFillerOrphanAt:coord]) {
                                  [result iterm_appendString:@" "
                                              withAttributes:attributeProvider(theChar)];
                              }
                          } else if (theChar.code != DWC_RIGHT &&
                                     theChar.code != DWC_SKIP) {
                              // Normal character
                              [result iterm_appendString:ScreenCharToStr(&theChar)
                                          withAttributes:attributeProvider(theChar)];
                          }
                          return NO;
                      }
                       eolBlock:^BOOL(unichar code, int numPreceedingNulls, int line) {
                           if (pad) {
                               for (int i = 0; i < numPreceedingNulls; i++) {
                                   [result iterm_appendString:@" "
                                               withAttributes:attributeProvider([self defaultChar])];
                               }
                           }
                           [result iterm_appendString:@"\n"
                                       withAttributes:attributeProvider([self defaultChar])];
                           return NO;
                       }];
    
    return result;
}

#pragma mark - Private

- (VT100GridCoord)canonicalizedLocation:(VT100GridCoord)location {
    int xLimit = [self xLimit];
    if (location.x >= xLimit) {
        location.x = xLimit - 1;
    }
    return location;
}

- (int)lineNumberWithStartOfWholeLineIncludingLine:(int)y
                              respectContinuations:(BOOL)respectContinuations
{
    int i = y;
    while (i > 0 && [self lineHasSoftEol:i - 1 respectContinuations:respectContinuations]) {
        i--;
    }
    return i;
}

- (int)lineNumberWithEndOfWholeLineIncludingLine:(int)y
                            respectContinuations:(BOOL)respectContinuations
{
    int i = y + 1;
    int maxY = [_dataSource numberOfLines];
    while (i < maxY && [self lineHasSoftEol:i - 1 respectContinuations:respectContinuations]) {
        i++;
    }
    return i - 1;
}

- (BOOL)lineHasSoftEol:(int)y respectContinuations:(BOOL)respectContinuations
{
    screen_char_t *theLine = [_dataSource getLineAtIndex:y];
    int width = [_dataSource width];
    if ([self xLimit] != width) {
        return YES;
    }
    if (respectContinuations) {
        return (theLine[width].code == EOL_SOFT ||
                (theLine[width - 1].code == '\\' && !theLine[width - 1].complexChar));
    } else {
        return theLine[width].code == EOL_SOFT;
    }
}

- (BOOL)isTabFillerOrphanAt:(VT100GridCoord)start {
    __block BOOL result = YES;
    [self searchFrom:start
             forward:YES
        forCharacterMatchingFilter:^BOOL (screen_char_t theChar, VT100GridCoord coord) {
            if (coord.y != start.y) {
                result = YES;
                return YES;
            }
            if (theChar.code != TAB_FILLER) {
                result = (theChar.code != '\t');
                return YES;
            }
            return NO;
        }];
    return result;
}

- (NSString *)wrappedStringAt:(VT100GridCoord)coord
                      forward:(BOOL)forward
          respectHardNewlines:(BOOL)respectHardNewlines
                     maxChars:(int)maxChars {
    if ([self hasLogicalWindow]) {
        respectHardNewlines = NO;
    }
    VT100GridWindowedRange range;
    if (respectHardNewlines) {
        range = [self rangeForWrappedLineEncompassing:coord respectContinuations:YES];
    } else {
        VT100GridCoordRange coordRange =
            VT100GridCoordRangeMake(_logicalWindow.location,
                                    MAX(0, coord.y - 10),
                                    [self xLimit],
                                    MIN([_dataSource numberOfLines] - 1, coord.y + 10));
        range = [self windowedRangeWithRange:coordRange];
    }
    iTermTextExtractorNullPolicy nullPolicy;
    if (forward) {
        nullPolicy = kiTermTextExtractorNullPolicyFromStartToFirst;
        range.coordRange.start = coord;
        if (VT100GridCoordOrder(range.coordRange.start,
                                range.coordRange.end) != NSOrderedAscending) {
            return @"";
        }
    } else {
        nullPolicy = kiTermTextExtractorNullPolicyFromLastToEnd;
        // This doesn't include the boundary character when returning a prefix because we don't
        // want it twice when getting the prefix and suffix at the same coord.
        range.coordRange.end = coord;
        if (VT100GridCoordOrder(range.coordRange.start,
                                range.coordRange.end) != NSOrderedAscending) {
            return @"";
        }
    }
    NSString *content =
            [self contentInRange:range
                      nullPolicy:nullPolicy
                             pad:NO
              includeLastNewline:NO
          trimTrailingWhitespace:NO
                    cappedAtSize:maxChars];
    if (!respectHardNewlines) {
        content = [content stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    }
    return content;
}

- (void)enumerateCharsInRange:(VT100GridWindowedRange)range
                    charBlock:(BOOL (^)(screen_char_t theChar, VT100GridCoord coord))charBlock
                     eolBlock:(BOOL (^)(unichar code, int numPreceedingNulls, int line))eolBlock {
    int width = [_dataSource width];
    int startx = VT100GridWindowedRangeStart(range).x;
    int endx = range.columnWindow.length ? range.columnWindow.location + range.columnWindow.length
                                         : [_dataSource width];
    int bound = [_dataSource numberOfLines] - 1;
    BOOL fullWidth = ((range.columnWindow.location == 0 && range.columnWindow.length == width) ||
                      range.columnWindow.length <= 0);
    int left = range.columnWindow.length ? range.columnWindow.location : 0;
    for (int y = MAX(0, range.coordRange.start.y); y <= MIN(bound, range.coordRange.end.y); y++) {
        if (y == range.coordRange.end.y) {
            // Reduce endx for last line.
            endx = range.columnWindow.length ? VT100GridWindowedRangeEnd(range).x
                                             : range.coordRange.end.x;
        }
        screen_char_t *theLine = [_dataSource getLineAtIndex:y];
        
        // Count number of nulls at end of line.
        int numNulls = 0;
        for (int x = endx - 1; x >= range.columnWindow.location; x--) {
            if (theLine[x].code == 0) {
                ++numNulls;
            } else {
                break;
            }
        }
        
        // Iterate over characters up to terminal nulls.
        for (int x = MAX(range.columnWindow.location, startx); x < endx - numNulls; x++) {
            if (charBlock) {
                if (charBlock(theLine[x], VT100GridCoordMake(x, y))) {
                    return;
                }
            }
        }

        BOOL haveReachedEol = YES;
        if (y == range.coordRange.end.y) {
            haveReachedEol = numNulls > 0;
        }
        if (eolBlock && haveReachedEol) {
            BOOL stop;
            if (fullWidth) {
                stop = eolBlock(theLine[width].code, numNulls, y);
            } else {
                stop = eolBlock(numNulls ? EOL_HARD : EOL_SOFT, numNulls, y);
            }
            if (stop) {
                return;
            }
        }
        startx = left;
    }
}

- (void)enumerateInReverseCharsInRange:(VT100GridWindowedRange)range
                             charBlock:(BOOL (^)(screen_char_t theChar, VT100GridCoord coord))charBlock
                              eolBlock:(BOOL (^)(unichar code, int numPreceedingNulls, int line))eolBlock {
    int xLimit = range.columnWindow.length == 0 ? [_dataSource width] :
        (range.columnWindow.location + range.columnWindow.length);
    int initialX = MIN(xLimit - 1, range.coordRange.end.x - 1);
    int trueWidth = [_dataSource width];
    const int yLimit = MAX(0, range.coordRange.start.y);
    for (int y = MIN([_dataSource numberOfLines] - 1, range.coordRange.end.y);
         y >= yLimit;
         y--) {
        screen_char_t *theLine = [_dataSource getLineAtIndex:y];
        int x = initialX;
        int xmin;
        if (y == yLimit) {
            xmin = VT100GridWindowedRangeStart(range).x;
        } else {
            xmin = range.columnWindow.location;
        }
        if (x == xLimit - 1) {
            int numNulls = 0;
            while (x >= xmin && theLine[x].code == 0 && !theLine[x].complexChar) {
                ++numNulls;
                --x;
            }
            if (eolBlock) {
                if (xLimit == trueWidth) {
                    if (eolBlock(theLine[trueWidth].code, numNulls, y)) {
                        return;
                    }
                } else {
                    if (numNulls) {
                        if (eolBlock(EOL_HARD, numNulls, y)) {
                            return;
                        }
                    } else {
                        if (eolBlock(EOL_SOFT, 0, y)) {
                            return;
                        }
                    }
                }
            }
        }
        if (charBlock) {
            for (; x >= xmin; x--) {
                if (charBlock(theLine[x], VT100GridCoordMake(x, y))) {
                    return;
                }
            }
        }
        initialX = xLimit - 1;
    }
}

- (int)lengthOfLine:(int)line {
    screen_char_t *theLine = [_dataSource getLineAtIndex:line];
    int x;
    for (x = [_dataSource width] - 1; x >= 0; x--) {
        if (theLine[x].code || theLine[x].complexChar) {
            break;
        }
    }
    return x + 1;
}

- (NSIndexSet *)possibleColumnDividerIndexesAround:(VT100GridCoord)coord {
    NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
    VT100GridCoordRange theRange =
        VT100GridCoordRangeMake(0, coord.y, [_dataSource width], coord.y);
    [self enumerateCharsInRange:VT100GridWindowedRangeMake(theRange, 0, 0)
                      charBlock:^BOOL(screen_char_t theChar, VT100GridCoord theCoord) {
                          if (!theChar.complexChar && theChar.code == '|') {
                              [indexes addIndex:theCoord.x];
                          }
                          return NO;
                      }
                       eolBlock:NULL];
    return indexes;
}

- (BOOL)coordContainsColumnDivider:(VT100GridCoord)coord {
    int n = 1;
    for (int y = coord.y - 1; y >= 0 && y > coord.y - kNumCharsToSearchForDivider; y--) {
        if ([[self stringForCharacterAt:VT100GridCoordMake(coord.x, y)] isEqualToString:@"|"]) {
            n++;
        } else {
            break;
        }
    }
    int limit = [_dataSource numberOfLines];
    for (int y = coord.y + 1; y < limit && y < coord.y + kNumCharsToSearchForDivider; y++) {
        if ([[self stringForCharacterAt:VT100GridCoordMake(coord.x, y)] isEqualToString:@"|"]) {
            n++;
        } else {
            break;
        }
    }
    return n >= kNumCharsToSearchForDivider;
}

- (int)xLimit {
    if (!_logicalWindow.length) {
        return [_dataSource width];
    } else {
        return _logicalWindow.location + _logicalWindow.length;
    }
}

- (screen_char_t)defaultChar {
    screen_char_t defaultChar = { 0 };
    defaultChar.foregroundColorMode = ColorModeAlternate;
    defaultChar.foregroundColor = ALTSEM_DEFAULT;
    defaultChar.backgroundColorMode = ColorModeAlternate;
    defaultChar.backgroundColor = ALTSEM_DEFAULT;
    return defaultChar;
}

- (VT100GridWindowedRange)windowedRangeWithRange:(VT100GridCoordRange)range {
    VT100GridWindowedRange windowedRange;
    windowedRange.coordRange = range;
    windowedRange.columnWindow = _logicalWindow;
    return windowedRange;
}

- (VT100GridCoord)coordLockedToWindow:(VT100GridCoord)coord {
    if (_logicalWindow.length == 0) {
        return coord;
    }
    coord.x = MIN(MAX(coord.x, _logicalWindow.location),
                  _logicalWindow.location + _logicalWindow.length - 1);
    return coord;
}

- (screen_char_t)characterAt:(VT100GridCoord)coord {
    screen_char_t *theLine = [_dataSource getLineAtIndex:coord.y];
    return theLine[coord.x];
}

@end
