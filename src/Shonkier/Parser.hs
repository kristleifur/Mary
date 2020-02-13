module Shonkier.Parser where

import Control.Applicative
import Data.Attoparsec.Text
import Data.Char

import Shonkier.Syntax

punc :: Char -> Parser ()
punc c = () <$ skipSpace <* char c <* skipSpace

sep :: Parser () -> Parser x -> Parser [x]
sep s p = (:) <$> p <*> many (id <$ s <*> p) <|> pure []

term :: Parser Term
term = weeTerm >>= moreTerm

weeTerm :: Parser Term
weeTerm =
  Atom <$ char '\'' <*> some (satisfy isAlphaNum)
  <|>
  Var <$> some (satisfy isAlphaNum)
  <|>
  flip (foldr Cell) <$ char '['
    <*> many (skipSpace *> term) <* skipSpace
    <*> (id <$ char '|' <* skipSpace <*> term <|> pure (Atom ""))
    <* skipSpace <* char ']'
  <|>
  Fun <$ char '{' <* skipSpace <*> sep (punc '|') clause <* skipSpace <* char '}'

moreTerm :: Term -> Parser Term
moreTerm t = ((App t <$ punc '(' <*> sep (punc ',') term <* punc ')') >>= moreTerm)
           <|> pure t


clause :: Parser Clause
clause = (,) <$> sep (punc ',') pattern <* skipSpace <* char '-' <* char '>' <* skipSpace
             <*> term
  <|> (,) [] <$> term

pattern :: Parser Pattern
pattern =
  PAtom <$ char '\'' <*> some (satisfy isAlphaNum)
  <|>
  PBind <$> some (satisfy isAlphaNum)
  <|>
  flip (foldr PCell) <$ char '[' <*> many (skipSpace *> pattern) <* skipSpace
          <*> (id <$ char '|' <* skipSpace <*> pattern <|> pure (PAtom ""))
           <* skipSpace <* char ']'
