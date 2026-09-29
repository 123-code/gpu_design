// software/src/parser.rs
use crate::token::Token;
use crate::ast::{Stmt, Expr, Op, IdentityReg};

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
//   parse_expression -> parse_comparison (< ==) -> parse_shift (<< >>)
//   -> parse_additive (+ -) -> parse_multiplicative (*) -> parse_operand
// Each level LOOPS over its operators (left-associative) and calls the next level
// down for each operand, so + binds tighter than < and a - b - c == (a - b) - c.
    fn parse_expression(&mut self) -> Result<Expr, String> {
        self.parse_comparison()
    }

    // Lowest precedence: comparisons (<, ==)
    fn parse_comparison(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_shift()?;
        while let Some(op) = self.peek().and_then(|t| match t {
            Token::LessThan => Some(Op::LessThan),
            Token::Equal => Some(Op::Equal),
            _ => None,
        }) {
            self.advance(); // consume the operator
            let right = self.parse_shift()?;
            left = Expr::BinaryOp { left: Box::new(left), op, right: Box::new(right) };
        }
        Ok(left)
    }

    // Shifts (<<, >>): the shift amount is a value, like any other operand
    fn parse_shift(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_additive()?;
        while let Some(op) = self.peek().and_then(|t| match t {
            Token::ShiftLeft => Some(Op::Shl),
            Token::ShiftRight => Some(Op::Shr),
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
        let mut left = self.parse_multiplicative()?;
        while let Some(op) = self.peek().and_then(|t| match t {
            Token::Plus => Some(Op::Add),
            Token::Minus => Some(Op::Sub),
            _ => None,
        }) {
            self.advance(); // consume the operator
            let right = self.parse_multiplicative()?;
            left = Expr::BinaryOp { left: Box::new(left), op, right: Box::new(right) };
        }
        Ok(left)
    }

    // Highest binary precedence: multiplicative (*)
    fn parse_multiplicative(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_operand()?;
        while self.peek() == Some(&Token::Star) {
            self.advance(); // consume '*'
            let right = self.parse_operand()?;
            left = Expr::BinaryOp { left: Box::new(left), op: Op::Mul, right: Box::new(right) };
        }
        Ok(left)
    }

    
    fn parse_operand(&mut self) -> Result<Expr, String> {
        if self.peek() == Some(&Token::OpenParen) {
            self.advance(); // consume '('
            let inner = self.parse_expression()?;
            self.consume(Token::CloseParen, "Expected ')' after expression")?;
            return Ok(inner);
        }
        match self.advance() {
            Some(Token::Num(val)) => Ok(Expr::Number(*val)),
            Some(Token::Ident(name)) => {
                let name = name.clone();
                // SIMT identity reads: bare keywords that evaluate to a register.
                match name.as_str() {
                    "tid" => return Ok(Expr::ThreadId(IdentityReg::Tid)),
                    "bid" => return Ok(Expr::ThreadId(IdentityReg::Bid)),
                    "bdim" => return Ok(Expr::ThreadId(IdentityReg::Bdim)),
                    _ => {}
                }
                if name == "max" && self.peek() == Some(&Token::OpenParen) {
                    self.consume(Token::OpenParen, "Expected '(' after max")?;
                    let a = self.parse_expression()?;
                    self.consume(Token::Comma, "Expected ',' between max operands")?;
                    let b = self.parse_expression()?;
                    self.consume(Token::CloseParen, "Expected ')' after max operands")?;
                    return Ok(Expr::Max(Box::new(a), Box::new(b)));
                }
                if name == "mem" && self.peek() == Some(&Token::OpenBracket) {
                    self.consume(Token::OpenBracket, "Expected '[' after mem")?;
                    
                    let index_expr = self.parse_expression()?;
                    
                    self.consume(Token::CloseBracket, "Expected ']' after memory index")?;
                    
                   
                    return Ok(Expr::MemoryAccess(Box::new(index_expr)));
                }
                
                
                Ok(Expr::Variable(name))
            }
            _ => Err("Expected a number, variable, or mem[] in expression".to_string()),
        }
    }



    
fn parse_statement(&mut self) -> Result<Stmt, String> {
        match self.peek() {
            Some(Token::Manifest) => self.parse_manifest(),
            Some(Token::Yeet) => self.parse_yeet(),
            Some(Token::GrindUntil) => self.parse_grind_until(),
            Some(Token::If) => self.parse_if(),
            Some(Token::CrunchPush) => self.parse_crunch_push(), // NEW
            Some(Token::CrunchFire) => self.parse_crunch_fire(), // NEW
            Some(Token::FcReset)    => self.parse_nullary(Token::FcReset, Stmt::FcReset),
            Some(Token::FcFinalize) => self.parse_nullary(Token::FcFinalize, Stmt::FcFinalize),
            Some(Token::Advance)    => self.parse_advance(),
            Some(Token::Wbase)      => self.parse_wbase(),
            Some(Token::FcMac)      => self.parse_fc_mac(),
            Some(Token::FcBest)     => self.parse_fc_best(),
            _ => {
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
        
        if self.peek() == Some(&Token::Ident("mem".to_string())) {
            self.advance(); 
            self.consume(Token::OpenBracket, "Expected '[' after mem")?;
            let address = self.parse_expression()?;
            self.consume(Token::CloseBracket, "Expected ']'")?;
            
            self.consume(Token::Assign, "Expected '='")?;
            let value = self.parse_expression()?;
            self.consume(Token::Semi, "Expected ';'")?;
            
            return Ok(Stmt::JoseIgnacioStore { address, value });
        }

        
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

    // if (<cond>) { body }
    fn parse_if(&mut self) -> Result<Stmt, String> {
        self.consume(Token::If, "Expected 'if'")?;
        self.consume(Token::OpenParen, "Expected '(' before if condition")?;
        let condition = self.parse_expression()?;
        self.consume(Token::CloseParen, "Expected ')' after if condition")?;
        self.consume(Token::OpenBrace, "Expected '{' to start if body")?;
        let mut body = Vec::new();
        while self.peek() != Some(&Token::CloseBrace) {
            body.push(self.parse_statement()?);
        }
        self.consume(Token::CloseBrace, "Expected '}' to close if body")?;
        Ok(Stmt::JoseIgnacioIf { condition, body })
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

    // Parses: crunch_push <expr>;
    // crunch_push <pixel>;            weight defaults to R0
    // crunch_push <pixel>, <weight>;  explicit (pixel, weight) pair
    fn parse_crunch_push(&mut self) -> Result<Stmt, String> {
        self.consume(Token::CrunchPush, "Expected 'crunch_push'")?;
        let pixel = self.parse_expression()?;
        let weight = if self.peek() == Some(&Token::Comma) {
            self.advance(); // consume ','
            Some(self.parse_expression()?)
        } else {
            None
        };
        self.consume(Token::Semi, "Expected ';' after crunch_push")?;
        Ok(Stmt::CrunchPush { pixel, weight })
    }

    // Parses: crunch_fire <variable>;  or  crunch_fire <variable>, <byte 0..3>;
    fn parse_crunch_fire(&mut self) -> Result<Stmt, String> {
        self.consume(Token::CrunchFire, "Expected 'crunch_fire'")?;
        
        let dest = match self.advance() {
            Some(Token::Ident(n)) => n.clone(),
            _ => return Err("Expected destination variable name after crunch_fire".to_string()),
        };
        
        let byte = if self.peek() == Some(&Token::Comma) {
            self.advance(); // consume ','
            match self.advance() {
                Some(Token::Num(n)) if *n <= 3 => *n as u8,
                _ => return Err("crunch_fire byte must be 0, 1, 2 or 3".to_string()),
            }
        } else {
            0
        };
        self.consume(Token::Semi, "Expected ';' after crunch_fire")?;
        Ok(Stmt::CrunchFire { dest, byte })
    }



    // A keyword statement with no operands: <kw>;
    fn parse_nullary(&mut self, kw: Token, stmt: Stmt) -> Result<Stmt, String> {
        self.consume(kw, "Expected keyword")?;
        self.consume(Token::Semi, "Expected ';'")?;
        Ok(stmt)
    }

    // advance;  or  advance <n>;
    fn parse_advance(&mut self) -> Result<Stmt, String> {
        self.consume(Token::Advance, "Expected 'advance'")?;
        let n = match self.peek() {
            Some(Token::Num(n)) => { let n = *n; self.advance(); n }
            _ => 1,
        };
        self.consume(Token::Semi, "Expected ';' after advance")?;
        Ok(Stmt::Advance(n))
    }

    // wbase <n>;
    fn parse_wbase(&mut self) -> Result<Stmt, String> {
        self.consume(Token::Wbase, "Expected 'wbase'")?;
        let n = match self.advance() {
            Some(Token::Num(n)) => *n,
            _ => return Err("Expected a number after wbase".to_string()),
        };
        self.consume(Token::Semi, "Expected ';' after wbase")?;
        Ok(Stmt::Wbase(n))
    }

    // fc_mac <feature>, <weight>;
    fn parse_fc_mac(&mut self) -> Result<Stmt, String> {
        self.consume(Token::FcMac, "Expected 'fc_mac'")?;
        let feature = self.parse_expression()?;
        self.consume(Token::Comma, "Expected ',' between fc_mac operands")?;
        let weight = self.parse_expression()?;
        self.consume(Token::Semi, "Expected ';' after fc_mac")?;
        Ok(Stmt::FcMac { feature, weight })
    }

    // fc_best <variable>;
    fn parse_fc_best(&mut self) -> Result<Stmt, String> {
        self.consume(Token::FcBest, "Expected 'fc_best'")?;
        let dest = match self.advance() {
            Some(Token::Ident(n)) => n.clone(),
            _ => return Err("Expected destination variable after fc_best".to_string()),
        };
        self.consume(Token::Semi, "Expected ';' after fc_best")?;
        Ok(Stmt::FcBest { dest })
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