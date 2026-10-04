/* A Bison parser, made by GNU Bison 3.8.2.  */

/* Bison interface for Yacc-like parsers in C

   Copyright (C) 1984, 1989-1990, 2000-2015, 2018-2021 Free Software Foundation,
   Inc.

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <https://www.gnu.org/licenses/>.  */

/* As a special exception, you may create a larger work that contains
   part or all of the Bison parser skeleton and distribute that work
   under terms of your choice, so long as that work isn't itself a
   parser generator using the skeleton or a modified version thereof
   as a parser skeleton.  Alternatively, if you modify or redistribute
   the parser skeleton itself, you may (at your option) remove this
   special exception, which will cause the skeleton and the resulting
   Bison output files to be licensed under the GNU General Public
   License without this special exception.

   This special exception was added by the Free Software Foundation in
   version 2.2 of Bison.  */

/* DO NOT RELY ON FEATURES THAT ARE NOT DOCUMENTED in the manual,
   especially those whose name start with YY_ or yy_.  They are
   private implementation details that can be changed or removed.  */

#ifndef YY_PARSE_EVENTS_UTIL_PARSE_EVENTS_BISON_H_INCLUDED
# define YY_PARSE_EVENTS_UTIL_PARSE_EVENTS_BISON_H_INCLUDED
/* Debug traces.  */
#ifndef YYDEBUG
# define YYDEBUG 0
#endif
#if YYDEBUG
extern int parse_events_debug;
#endif

/* Token kinds.  */
#ifndef YYTOKENTYPE
# define YYTOKENTYPE
  enum yytokentype
  {
    YYEMPTY = -2,
    YYEOF = 0,                     /* "end of file"  */
    YYerror = 256,                 /* error  */
    YYUNDEF = 257,                 /* "invalid token"  */
    PE_START_EVENTS = 258,         /* PE_START_EVENTS  */
    PE_START_TERMS = 259,          /* PE_START_TERMS  */
    PE_VALUE = 260,                /* PE_VALUE  */
    PE_TERM = 261,                 /* PE_TERM  */
    PE_EVENT_NAME = 262,           /* PE_EVENT_NAME  */
    PE_RAW = 263,                  /* PE_RAW  */
    PE_NAME = 264,                 /* PE_NAME  */
    PE_MODIFIER_EVENT = 265,       /* PE_MODIFIER_EVENT  */
    PE_MODIFIER_BP = 266,          /* PE_MODIFIER_BP  */
    PE_BP_COLON = 267,             /* PE_BP_COLON  */
    PE_BP_SLASH = 268,             /* PE_BP_SLASH  */
    PE_PREFIX_MEM = 269,           /* PE_PREFIX_MEM  */
    PE_ERROR = 270,                /* PE_ERROR  */
    PE_DRV_CFG_TERM = 271          /* PE_DRV_CFG_TERM  */
  };
  typedef enum yytokentype yytoken_kind_t;
#endif

/* Value type.  */
#if ! defined YYSTYPE && ! defined YYSTYPE_IS_DECLARED
union YYSTYPE
{
#line 99 "util/parse-events.y"

	char *str;
	u64 num;
	struct parse_events_modifier mod;
	enum parse_events__term_type term_type;
	struct list_head *list_evsel;
	struct parse_events_terms *list_terms;
	struct parse_events_term *term;
	struct tracepoint_name {
		char *sys;
		char *event;
	} tracepoint_name;

#line 94 "util/parse-events-bison.h"

};
typedef union YYSTYPE YYSTYPE;
# define YYSTYPE_IS_TRIVIAL 1
# define YYSTYPE_IS_DECLARED 1
#endif

/* Location type.  */
#if ! defined YYLTYPE && ! defined YYLTYPE_IS_DECLARED
typedef struct YYLTYPE YYLTYPE;
struct YYLTYPE
{
  int first_line;
  int first_column;
  int last_line;
  int last_column;
};
# define YYLTYPE_IS_DECLARED 1
# define YYLTYPE_IS_TRIVIAL 1
#endif




int parse_events_parse (void *_parse_state, void *scanner);


#endif /* !YY_PARSE_EVENTS_UTIL_PARSE_EVENTS_BISON_H_INCLUDED  */
