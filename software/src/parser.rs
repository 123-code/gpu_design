// software/src/parser.rs
use crate::token::Token;
use crate::ast::{Stmt, Expr, Op};

pub struct Parser {
    tokens: Vec<Token>,
    position: usize,
}

impl Parser {
    pub fn new(tokens: Vec<Token>) -> Self {
        Parser { tokens, position: 0 }
    }

    // The main entry point: parses the whole file into a list of Statements
    pub fn parse_program(&mut self) -> Result<Vec<Stmt>, String> {
        let mut program = Vec::new();
        
        while self.position < self.tokens.len() {
            program.push(self.parse_statement()?);
        }
        
        Ok(program)
    }

// Expressions are parsed in precedence levels, lowest binding first:
//   parse_expression -> parse_comparison (< ==) -> parse_additive (+ -) -> parse_operand
// Each level LOOPS over its operators (left-associative) and calls the next level
// down for each operand, so + binds tighter than < and a - b - c == (a - b) - c.
    fn parse_expression(&mut self) -> Result<Expr, String> {
        self.parse_comparison()
    }

    // Lowest precedence: comparisons (<, ==)
    fn parse_comparison(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_additive()?;
        while let Some(op) = self.peek().and_then(|t| match t {
            Token::LessThan => Some(Op::LessThan),
            Token::Equal => Some(Op::Equal),
            _ => None,
        }) {
            self.advance(); // consume the operator
            let right = self.parse_additive()?;
            left = Expr::BinaryOp { left: Box::new(left), op, right: Box::new(right) };
        }
        Ok(left)
    }

    // Higher precedence: additive (+, -)
    fn parse_additive(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_operand()?;
        while let Some(op) = self.peek().and_then(|t| match t {
            Token::Plus => Some(Op::Add),
            Token::Minus => Some(Op::Sub),
            _ => None,
        }) {
            self.advance(); // consume the operator
            let right = self.parse_operand()?;
            left = Expr::BinaryOp { left: Box::new(left), op, right: Box::new(right) };
        }
        Ok(left)
    }

    // Atoms: a literal number or a variable name
    fn parse_operand(&mut self) -> Result<Expr, String> {
        match self.advance() {
            Some(Token::Num(val)) => Ok(Expr::Number(*val)),
            Some(Token::Ident(name)) => Ok(Expr::Variable(name.clone())),
            _ => Err("Expected a number or variable in expression".to_string()),
        }
    }



    
   fn parse_statement(&mut self) -> Result<Stmt, String> {
        match self.peek() {
            Some(Token::Manifest) => self.parse_manifest(),
            Some(Token::Yeet) => self.parse_yeet(),
            Some(Token::GrindUntil) => self.parse_grind_until(),
            _ => {
                // If it's just a variable name, it must be an assignment like: s = s + 1;
                self.parse_assignment()
            }
        }
    }

    fn parse_yeet(&mut self) -> Result<Stmt, String> {
        self.consume(Token::Yeet, "Expected 'yeet'")?;
        let value = self.parse_expression()?;
        self.consume(Token::Semi, "Expected ';' after yeet statement")?;
        Ok(Stmt::JoseIgnacioYeet(value))
    }

    fn parse_assignment(&mut self) -> Result<Stmt, String> {
        let name = match self.advance() {
            Some(Token::Ident(n)) => n.clone(),
            _ => return Err("Expected variable name for assignment".to_string()),
        };
        self.consume(Token::Assign, "Expected '=' in assignment")?;
        let value = self.parse_expression()?;
        self.consume(Token::Semi, "Expected ';' after assignment")?;
        Ok(Stmt::JoseIgnacioAssign { name, value })
    }

    fn parse_grind_until(&mut self) -> Result<Stmt, String> {
        self.consume(Token::GrindUntil, "Expected 'grind_until'")?;
        self.consume(Token::OpenParen, "Expected '(' before loop condition")?;
        
        
        let condition = self.parse_expression()?;
        
        self.consume(Token::CloseParen, "Expected ')' after loop condition")?;
        self.consume(Token::OpenBrace, "Expected '{' to start loop body")?;

        
        let mut body = Vec::new();
        while self.peek() != Some(&Token::CloseBrace) {
            body.push(self.parse_statement()?);
        }
        
        self.consume(Token::CloseBrace, "Expected '}' to close loop body")?;

        
        Ok(Stmt::JoseIgnacioLoop { condition, body })
    }

   
fn parse_manifest(&mut self) -> Result<Stmt, String> {
        self.consume(Token::Manifest, "Expected 'manifest'")?;
        
        let name = match self.advance() {
            Some(Token::Ident(n)) => n.clone(),
            _ => return Err("Expected variable name".to_string()),
        };

        self.consume(Token::Assign, "Expected '='")?;

        
        let value = self.parse_expression()?; 

        self.consume(Token::Semi, "Expected ';'")?;
        Ok(Stmt::JoseIgnacioVariable { name, value })
    }



    // Look at the current token without moving forward
    fn peek(&self) -> Option<&Token> {
        self.tokens.get(self.position)
    }

    // Grab the current token and move the pointer forward
    fn advance(&mut self) -> Option<&Token> {
        let token = self.tokens.get(self.position);
        self.position += 1;
        token
    }

    // Check if the current token matches what we expect, and consume it. Otherwise, error out.
    fn consume(&mut self, expected: Token, err_msg: &str) -> Result<(), String> {
        if self.peek() == Some(&expected) {
            self.advance();
            Ok(())
        } else {
            Err(err_msg.to_string())
        }
    }
}