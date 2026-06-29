//takes the raw string of code, 
// loops through characters
//  and mathces tthem to the tokens defined in token.rs

use crate::token::Token;
pub struct Lexer {
    input: Vec<char>,
    position: usize,
}

impl Lexer {
    pub fn new(input: &str) -> Self {
        Lexer {
            input: input.chars().collect(),
            position: 0,
        }
    }

    pub fn tokenize(&mut self) -> Result<Vec<Token>, String> {
        let mut tokens = Vec::new();

        while self.position < self.input.len() {
            let ch = self.input[self.position];

            // 1. Skip Whitespace
            if ch.is_whitespace() {
                self.position += 1;
                continue;
            }

            // 2. Match Single and Double Character Symbols
            match ch {
                ';' => { tokens.push(Token::Semi); self.position += 1; }
                '(' => { tokens.push(Token::OpenParen); self.position += 1; }
                ')' => { tokens.push(Token::CloseParen); self.position += 1; }
                '{' => { tokens.push(Token::OpenBrace); self.position += 1; }
                '}' => { tokens.push(Token::CloseBrace); self.position += 1; }
                '[' => { tokens.push(Token::OpenBracket); self.position += 1; }
                ']' => { tokens.push(Token::CloseBracket); self.position += 1; }
                '+' => { tokens.push(Token::Plus); self.position += 1; }
                '-' => { tokens.push(Token::Minus); self.position += 1; }
                '<' => { tokens.push(Token::LessThan); self.position += 1; }
                '=' => {
                    if self.peek() == Some('=') {
                        tokens.push(Token::Equal);
                        self.position += 2;
                    } else {
                        tokens.push(Token::Assign);
                        self.position += 1;
                    }
                }
                // `//` line comment: skip everything up to the end of the line.
                '/' if self.peek() == Some('/') => {
                    while self.position < self.input.len() && self.input[self.position] != '\n' {
                        self.position += 1;
                    }
                }
                
                // 3. Match Words (Keywords/Identifiers) and Numbers
                _ => {
                    if ch.is_alphabetic() || ch == '_' {
                        let word = self.read_identifier();
                        match word.as_str() {
                            "JoseIgnacioVariable" => tokens.push(Token::Manifest),
                            "JoseIgnacioLoop" => tokens.push(Token::GrindUntil),
                            "JoseIgnacioYeet" => tokens.push(Token::Yeet),
                            _ => tokens.push(Token::Ident(word)),
                        }
                    } else if ch.is_digit(10) {
                        let num = self.read_number()?;
                        tokens.push(Token::Num(num));
                    } else {
                        return Err(format!("Unexpected character '{}'", ch));
                    }
                }
            }
        }
        Ok(tokens)
    }

    fn peek(&self) -> Option<char> {
        if self.position + 1 < self.input.len() {
            Some(self.input[self.position + 1])
        } else {
            None
        }
    }

    fn read_identifier(&mut self) -> String {
        let start = self.position;
        while self.position < self.input.len() && (self.input[self.position].is_alphanumeric() || self.input[self.position] == '_') {
            self.position += 1;
        }
        self.input[start..self.position].iter().collect()
    }

    fn read_number(&mut self) -> Result<u8, String> {
        let start = self.position;
        while self.position < self.input.len() && self.input[self.position].is_digit(10) {
            self.position += 1;
        }
        let num_str: String = self.input[start..self.position].iter().collect();
        num_str.parse::<u8>().map_err(|_| format!("Number {} is too big for 8-bit (0-255 max)", num_str))
    }
}