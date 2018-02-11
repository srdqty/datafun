%{
open Util
open Ast

let map f g (x,y) = (Option.map f x, Option.map g y)
%}

%token
/* punctuation */ DOT COMMA UNDER SEMI COLON BANG PLUS DASH ASTERISK SLASH ARROW
DBLARROW BAR LE LT GE GT EQ EQEQ RPAREN LPAREN RBRACE LBRACE RBRACK LBRACK
/* keywords */ TYPE DEF THE LET IN END EMPTY OR FOR DO FIX AS FN CASE BOX UNBOX
IF THEN ELSE
/* end of file */ EOF

%token <Ast.base> BASE          /* base types */
%token <Ast.lit> LITERAL        /* literals */
%token <string> ID CAPID        /* lower/uppercase identifiers */

/* ---------- Associativity / fixity ---------- */
// This seems to force "Foo x" (and similar) to parse as
//
//     Tag "Foo" (Var "x")
//
// rather than
//
//     App (Tag "Foo" (Tuple [])) (Var "x")
//
%right CAPID UNDER LPAREN LITERAL LBRACE ID EMPTY

/* ---------- Types for nonterminals ---------- */
%start <unit> unused
%start <Ast.tp> tp test_tp
%start <Ast.pat> pat test_pat
%start <Ast.expr> exp test_exp
%start <Ast.pat option * Ast.expr option> patexp test_patexp
%start <Ast.expr Ast.decl list> decls test_decls

%%
/* Argh. */
unused: ASTERISK DASH DO DOT END EQEQ FIX GE GT LE LT PLUS SLASH {()};

/* ---------- Types ---------- */
test_tp: tp EOF { $1 }
tp:
| tp_arrow {$1}
| separated_nonempty_list(BAR, CAPID tp_atom {$1,$2}) {Sum $1}

tp_arrow: tp_product            { $1 }
| tp_product DBLARROW tp_arrow  { Arrow($1, $3) }
| tp_product ARROW tp_arrow     { Arrow(Box $1, $3) }

tp_product: tp_atom { $1 }
| tp_atom COMMA { Product [$1] }
| tp_atom nonempty_list(COMMA tp_atom { $2 }) { Product($1::$2) }

tp_atom:
| LPAREN RPAREN     { Product [] }
| BASE              { Base $1 }
| ID                { Name $1 }
| BANG tp_atom      { Box $2 }
| LBRACE tp RBRACE  { Set $2 }
| LPAREN tp RPAREN  { $2 }

/* ---------- Decls ---------- */
test_decls: decls EOF {$1}
decls: SEMI* separated_list(SEMI*,decl) {$2}
decl:
| TYPE ID EQ tp {Type($2,$4) }
| DEF pat_atom option(COLON tp {$2}) def_exp { Def($2,$3,$4) }

def_exp:
| EQ exp { $2 }
| fnexpr { E(($symbolstartpos,$endpos), $1) }

fnexpr: FN args DBLARROW exp { Lam($2,$4) }
args: list(pat_atom) {$1}

/* ---------- Comprehensions ---------- */
comps: separated_list(COMMA, comp) {$1}
comp:
| exp_app { When $1 }
| pat_app IN exp_app { In($1,$3) }
| exp_app LBRACK pat RBRACK { In($3,$1) }

/* ---------- Patterns/expressions ----------
 *
 * We collapse these as an awful hack to make parsing comprehensions LR(1).
 * In particular, both `PAT in EXPR` and `EXPR` are valid comprehensions.
 * With PAT and EXPR as separate productions, menhir complains and gives us
 * a reduce/reduce conflict. This way it Just Works, at the expense of having
 * to manually "parse both ways at once", so to speak.
 */
%inline annot(X): X
    { match $1 with
      | None, None -> $syntaxerror
      | x, None    -> x, None
      | x, Some y  -> x, Some (E(($symbolstartpos,$endpos), y)) }
%inline getPat(X): X { match fst $1 with | Some x -> x | None -> $syntaxerror }
%inline getExp(X): X { match snd $1 with | Some x -> x | None -> $syntaxerror }

test_patexp: patexp EOF {$1}; test_exp: exp EOF {$1}; test_pat: pat EOF {$1}
patexp: annot(pe) {$1}
patexp_infix: annot(pe_infix) {$1}
patexp_app: annot(pe_app) {$1}
patexp_atom: annot(pe_atom) {$1}

pat: getPat(patexp) {$1}; exp: getExp(patexp) {$1}
pat_infix: getPat(patexp_infix) {$1}; exp_infix: getExp(patexp_infix) {$1}
pat_app: getPat(patexp_app) {$1}; exp_app: getExp(patexp_app) {$1}
pat_atom: getPat(patexp_atom) {$1}; exp_atom: getExp(patexp_atom) {$1}

pe: pe_infix {$1} | e {None, Some $1}
e:
| THE tp_atom exp    { The($2,$3) }
| pat_infix AS exp   { Fix($1,$3) }
| fnexpr             { $1 }
| LET decls IN exp   { Let($2,$4) }
| FOR LPAREN c=comps RPAREN e=exp { For(c,e) }
/* TODO: use precedence(?) to resolve the shift/reduce conflict here */
| CASE exp_infix nonempty_list(BAR pat DBLARROW exp {$2,$4}) { Case($2,$3) }
| IF exp THEN exp ELSE exp
  { Case($2, [PLit (LBool true), $4; PLit (LBool false), $6]) }

pe_infix: pe_app {$1}
| patexp_app nonempty_list(COMMA patexp_app {$2})
  { let (xs,ys) = List.split ($1::$2) in
    map (fun x -> PTuple x) (fun x -> Tuple x)
        (Option.list xs, Option.list ys) }
/* expressions only */
| ioption(OR) exp_app nonempty_list(OR exp_app {$2})
  { None, Some (Lub ($2::$3)) }

pe_app: pe_atom {$1}
| CAPID patexp_atom { map (fun x -> PTag($1,x)) (fun x -> Tag($1,x)) $2 }
| BOX patexp_atom { map (fun x -> PBox x) (fun x -> Box x) $2 }
/* expressions only */
| UNBOX exp_atom { None, Some (Unbox $2) }
| exp_app exp_atom { None, Some (App ($1,$2)) }

pe_atom:
| CAPID { Some (PTag ($1, PTuple [])),
          Some (Tag ($1, E(($symbolstartpos,$endpos), Tuple []))) }
| ID        { Some (PVar $1), Some (Var $1) }
| LITERAL   { Some (PLit $1), Some (Lit $1) }
| LPAREN RPAREN { Some (PTuple []), Some (Tuple []) }
| LPAREN patexp_app COMMA RPAREN
  { map (fun x -> PTuple [x]) (fun x -> Tuple [x]) $2 }
| LPAREN pe RPAREN { $2 }
/* patterns only */
| UNDER     { Some PWild, None }
/* expressions only */
| EMPTY     { None, Some (Lub []) }
| LBRACE separated_list(COMMA, exp_app) RBRACE { None, Some (MkSet $2) }
| LBRACE exp_app BAR comps RBRACE
  { None, Some (For ($4, E(($symbolstartpos,$endpos), MkSet([$2])))) }
