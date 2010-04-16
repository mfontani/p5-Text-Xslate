#define PERL_NO_GET_CONTEXT
#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>

#include "ppport.h"

/* buffer size coefficient (bits), used for memory allocation */
/* (1 << 6) * U16_MAX = about 4 MiB */
#define TX_BUFFER_SIZE_C 6

#define XSLATE(name) static void CAT2(XSLATE_, name)(pTHX_ tx_state_t* const txst)

#define TX_st (txst)
#define TX_op (&(TX_st->code[TX_st->pc]))

#ifdef DEBUGGING
#define TX_st_sa  *tx_sv_safe(aTHX_ &(TX_st->sa),  "TX_st->sa",  __FILE__, __LINE__)
#define TX_st_sb  *tx_sv_safe(aTHX_ &(TX_st->sb),  "TX_st->sb",  __FILE__, __LINE__)
#define TX_op_arg *tx_sv_safe(aTHX_ &(TX_op->arg), "TX_st->arg", __FILE__, __LINE__)
static SV**
tx_sv_safe(pTHX_ SV** const svp, const char* const name, const char* const f, int const l) {
    if(UNLIKELY(*svp == NULL)) {
        croak("Xslate-panic: %s is NULL at %s line %d.\n", name, f, l);
    }
    else if(UNLIKELY(SvIS_FREED(*svp))) {
        croak("Xslate-panic: %s is a freed sv at %s line %d.\n", name, f, l);
    }
    return svp;
}
#else
#define TX_st_sa  (TX_st->sa)
#define TX_st_sb  (TX_st->sb)
#define TX_op_arg (TX_op->arg)
#endif

struct tx_code_s;
struct tx_state_s;

typedef struct tx_code_s  tx_code_t;
typedef struct tx_state_s tx_state_t;

typedef void (*tx_exec_t)(pTHX_ tx_state_t*);

struct tx_state_s {
    Size_t pc;       /* the program counter */
    line_t line;

    tx_code_t* code; /* compiled code */
    Size_t     code_len;

    SV* output;
    HV* vars;    /* template variables */
    AV* iter_v;  /* iterator variables */
    AV* iter_i;  /* iterator counter */

    /* registers */
    //IV ia;
    //IV ib;

    SV* sa;
    SV* sb;
};

struct tx_code_s {
    tx_exec_t exec_code;

    SV* arg;
};

static SV*
tx_fetch(pTHX_ const tx_state_t* const st, SV* const var, SV* const key) {
    SV* sv = NULL;
    if(sv_isobject(var)) {
        dSP;
        PUSHMARK(SP);
        XPUSHs(var);
        PUTBACK;

        ENTER;
        SAVETMPS;

        call_sv(key, G_SCALAR | G_METHOD | G_EVAL);

        SPAGAIN;
        sv = newSVsv(POPs);
        PUTBACK;

        if(sv_true(ERRSV)){
            croak("%d: Exception cought on %"SVf".%"SVf": %"SVf, (int)st->line,
                var, key, ERRSV);
        }

        FREETMPS;
        LEAVE;

        sv_2mortal(sv);
    }
    else if(SvROK(var)){
        SV* const rv = SvRV(var);
        if(SvTYPE(rv) == SVt_PVHV) {
            HE* const he = hv_fetch_ent((HV*)rv, key, FALSE, 0U);

            sv = he ? hv_iterval((HV*)rv, he) : &PL_sv_undef;
        }
        else if(SvTYPE(rv) == SVt_PVAV) {
            SV** const svp = av_fetch((AV*)rv, SvIV(key), FALSE);

            sv = svp ? *svp : &PL_sv_undef;
        }
        else {
            goto invalid_container;
        }
    }
    else {
        invalid_container:
        croak("%d: Cannot access '%"SVf"' (%s is not a container)", (int)st->line,
            key, SvOK(var) ? form("'%"SVf"'", var) : "undef");
    }
    return sv;
}

XSLATE(noop) {
    TX_st->pc++;
}

XSLATE(move_sa_to_sb) {
    TX_st_sb = TX_st_sa;

    TX_st->pc++;
}

XSLATE(literal) {
    TX_st_sa = TX_op_arg;

    TX_st->pc++;
}

XSLATE(fetch) { /* fetch a field from top */
    HV* const vars = TX_st->vars;
    HE* const he   = hv_fetch_ent(vars, TX_op_arg, FALSE, 0U);

    TX_st_sa = he ? hv_iterval(vars, he) : &PL_sv_undef;

    TX_st->pc++;
}

XSLATE(fetch_field) { /* fetch a field from a variable */
    SV* const var = TX_st_sa;
    SV* const key = TX_op_arg;

    TX_st_sa = tx_fetch(aTHX_ TX_st, var, key);
    TX_st->pc++;
}

XSLATE(print) {
    SV* const sv          = TX_st_sa;
    SV* const output      = TX_st->output;
    STRLEN len;
    const char*       cur = SvPV_const(sv, len);
    const char* const end = cur + len;

    (void)SvGROW(output, len + SvCUR(output) + 1);

    while(cur != end) {
        const char* parts;
        STRLEN      parts_len;

        switch(*cur) {
        case '<':
            parts     =        "&lt;";
            parts_len = sizeof("&lt;") - 1;
            break;
        case '>':
            parts     =        "&gt;";
            parts_len = sizeof("&gt;") - 1;
            break;
        case '&':
            parts     =        "&amp;";
            parts_len = sizeof("&amp;") - 1;
            break;
        case '"':
            parts     =        "&quot;";
            parts_len = sizeof("&quot;") - 1;
            break;
        case '\'':
            parts     =        "&#39;";
            parts_len = sizeof("&#39;") - 1;
            break;
        default:
            parts     = cur;
            parts_len = 1;
            break;
        }

        len = SvCUR(output) + parts_len + 1;
        (void)SvGROW(output, len);

        if(parts_len == 1) {
            *SvEND(output) = *parts;
        }
        else {
            Copy(parts, SvEND(output), parts_len, char);
        }
        SvCUR_set(output, SvCUR(output) + parts_len);

        cur++;
    }

    *SvEND(output) = '\0';

    TX_st->pc++;
}

XSLATE(print_s) {
    TX_st_sa = TX_op_arg;

    XSLATE_print(aTHX_ TX_st);
}

XSLATE(print_raw) {
    sv_catsv_nomg(TX_st->output, TX_st_sa);

    TX_st->pc++;
}

XSLATE(print_raw_s) {
    sv_catsv_nomg(TX_st->output, TX_op_arg);

    TX_st->pc++;
}

XSLATE(for_start) {
    SV* const sv = TX_st_sa;
    IV  const id = SvIV(TX_op_arg);
    AV* av;

    if(!(SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVAV)) {
        croak("%d: Iterator variables must be an ARRAY reference", (int)TX_st->line);
    }

    av = (AV*)SvRV(sv);
    SvREFCNT_inc_simple_void_NN(av);
    (void)av_store(TX_st->iter_v, id, (SV*)av);
    sv_setiv(*av_fetch(TX_st->iter_i, id, TRUE), 0); /* (re)set iterator */

    TX_st->pc++;
}

XSLATE(for_next) {
    SV* const idsv = TX_st_sa;
    IV  const id   = SvIV(idsv);
    AV* const av   = (AV*)AvARRAY(TX_st->iter_v)[ id ];
    SV* const i    =      AvARRAY(TX_st->iter_i)[ id ];

    assert(SvTYPE(av) == SVt_PVAV);

    //warn("for_next[%d %d]", (int)SvIV(i), (int)AvFILLp(av));
    if(++SvIVX(i) <= AvFILLp(av)) {
        TX_st->pc += SvIV(TX_op_arg); /* back to */
    }
    else {
        /* finish the for loop */

        /* don't need to clear iterator variables,
           they will be cleaned at the end of render() */

        /* IV const id = SvIV(TX_op_arg); */
        /* av_delete(TX_st->iter_v, id, G_DISCARD); */
        /* av_delete(TX_st->iter_i, id, G_DISCARD); */

        TX_st->pc++;
    }
}

XSLATE(fetch_iter) {
    SV* const idsv = TX_op_arg;
    IV  const id   = SvIV(idsv);
    AV* const av   = (AV*)AvARRAY(TX_st->iter_v)[ id ];
    SV* const i    =      AvARRAY(TX_st->iter_i)[ id ];
    SV** svp;

    assert(SvTYPE(av) == SVt_PVAV);

    //warn("fetch_iter[%d %d]", (int)SvIV(i), (int)AvFILLp(av));
    svp = av_fetch(av, SvIVX(i), FALSE);
    TX_st_sa = svp ? *svp : &PL_sv_undef;

    TX_st->pc++;
}

XSLATE(add) {
    TX_st_sa = sv_2mortal( newSVnv( SvNVx(TX_st_sb) + SvNVx(TX_st_sa) ) );

    TX_st->pc++;
}
XSLATE(sub) {
    TX_st_sa = sv_2mortal( newSVnv( SvNVx(TX_st_sb) - SvNVx(TX_st_sa) ) );

    TX_st->pc++;
}

XSLATE(cond_expr) {
    assert(TX_st_sa != NULL);
    if(sv_true(TX_st_sa)) {
        TX_st->pc++;
    }
    else {
        TX_st->pc += SvIVx(TX_op_arg);
    }
}

XSLATE(and) {
    if(sv_true(TX_st_sa)) {
        TX_st->pc++;
    }
    else {
        TX_st->pc += SvIVx(TX_op_arg);
    }
}

XSLATE(or) {
    if(!sv_true(TX_st_sa)) {
        TX_st->pc++;
    }
    else {
        TX_st->pc += SvIVx(TX_op_arg);
    }
}

XSLATE(not) {
    assert(TX_st_sa != NULL);
    TX_st_sa = boolSV( !sv_true(TX_st_sa) );

    TX_st->pc++;
}

XSLATE(eq) {
    SV* const sa = TX_st_sa;
    SV* const sb = TX_st_sb;

    /* undef == anything-defined is always false */
    if(SvOK(sa) && SvOK(sb)) {
        TX_st_sa = boolSV(sv_eq(sa, sb));
    }
    else {
        SvGETMAGIC(sa);
        SvGETMAGIC(sb);

        if(SvOK(sa) && SvOK(sb)) {
            TX_st_sa = boolSV(sv_eq(sa, sb));
        }
        else {
            TX_st_sa = &PL_sv_no;
        }
    }

    TX_st->pc++;
}

XSLATE(ne) {
    SV* const sa = TX_st_sa;
    SV* const sb = TX_st_sb;

    /* undef == anything-defined is always false */
    if(SvOK(sa) && SvOK(sb)) {
        TX_st_sa = boolSV(!sv_eq(sa, sb));
    }
    else {
        SvGETMAGIC(sa);
        SvGETMAGIC(sb);

        if(SvOK(sa) && SvOK(sb)) {
            TX_st_sa = boolSV(!sv_eq(sa, sb));
        }
        else {
            TX_st_sa = &PL_sv_yes;
        }
    }

    TX_st->pc++;
}

XSLATE(lt) {
    TX_st_sa = boolSV( SvNVx(TX_st_sb) < SvNVx(TX_st_sa) );
    TX_st->pc++;
}
XSLATE(le) {
    TX_st_sa = boolSV( SvNVx(TX_st_sb) <= SvNVx(TX_st_sa) );
    TX_st->pc++;
}
XSLATE(gt) {
    TX_st_sa = boolSV( SvNVx(TX_st_sb) > SvNVx(TX_st_sa) );
    TX_st->pc++;
}
XSLATE(ge) {
    TX_st_sa = boolSV( SvNVx(TX_st_sb) >= SvNVx(TX_st_sa) );
    TX_st->pc++;
}

XSLATE(pc_inc) {
    TX_st->pc += SvIV(TX_op_arg);
}

XSLATE(goto) {
    TX_st->pc = SvIV(TX_op_arg);
}

static SV*
xslate_exec(pTHX_ tx_state_t* const parent) {
    Size_t const code_len = parent->code_len;
    tx_state_t st;

    StructCopy(parent, &st, tx_state_t);

    while(st.pc < code_len) {
        Size_t const old_pc = st.pc;
        CALL_FPTR(st.code[st.pc].exec_code)(aTHX_ &st);

        if(UNLIKELY(old_pc == st.pc)) {
            croak("%d: pogram counter has not been changed", (int)st.pc);
        }
    }

    return st.output;
}

static MAGIC*
mgx_find(pTHX_ SV* const sv, const MGVTBL* const vtbl){
    MAGIC* mg;

    assert(sv   != NULL);
    assert(vtbl != NULL);

    for(mg = SvMAGIC(sv); mg; mg = mg->mg_moremagic){
        if(mg->mg_virtual == vtbl){
            assert(mg->mg_type == PERL_MAGIC_ext);
            return mg;
        }
    }

    croak("MAGIC(0x%p) not found", vtbl);
    return NULL; /* not reached */
}

static int
tx_mg_free(pTHX_ SV* const sv, MAGIC* const mg){
    tx_state_t* const st  = (tx_state_t*)mg->mg_ptr;
    tx_code_t* const code = st->code;
    I32 const len         = st->code_len;
    I32 i;

    for(i = 0; i < len; i++) {
        SvREFCNT_dec(code[i].arg);
    }

    Safefree(code);
    PERL_UNUSED_ARG(sv);

    SvREFCNT_dec(st->iter_v);
    SvREFCNT_dec(st->iter_i);

    return 0;
}

static MGVTBL xslate_vtbl = { /* for identity */
    NULL, /* get */
    NULL, /* set */
    NULL, /* len */
    NULL, /* clear */
    tx_mg_free, /* free */
    NULL, /* copy */
    NULL, /* dup */
    NULL,  /* local */
};

enum {
    TXOP_noop,
    TXOP_move_sa_to_sb,
    TXOP_literal,
    TXOP_fetch,
    TXOP_fetch_field,
    TXOP_fetch_iter,

    TXOP_print,
    TXOP_print_s,
    TXOP_print_raw,
    TXOP_print_raw_s,

    TXOP_for_start,
    TXOP_for_next,

    TXOP_add,
    TXOP_sub,

    TXOP_cond_expr,
    TXOP_and,
    TXOP_or,
    TXOP_not,
    TXOP_eq,
    TXOP_ne,
    TXOP_lt,
    TXOP_le,
    TXOP_gt,
    TXOP_ge,

    TXOP_pc_inc,
    TXOP_goto,

    TXOP_last
};

static const tx_exec_t tx_opcode[] = {
    XSLATE_noop,
    XSLATE_move_sa_to_sb,
    XSLATE_literal,
    XSLATE_fetch,
    XSLATE_fetch_field,
    XSLATE_fetch_iter,

    XSLATE_print,
    XSLATE_print_s,
    XSLATE_print_raw,
    XSLATE_print_raw_s,

    XSLATE_for_start,
    XSLATE_for_next,

    XSLATE_add,
    XSLATE_sub,

    XSLATE_cond_expr,
    XSLATE_and,
    XSLATE_or,
    XSLATE_not,
    XSLATE_eq,
    XSLATE_ne,
    XSLATE_lt,
    XSLATE_le,
    XSLATE_gt,
    XSLATE_ge,

    XSLATE_pc_inc,
    XSLATE_goto,

    NULL
};


#define REG_TXOP(name) (void)hv_stores(ops, STRINGIFY(name), newSViv(CAT2(TXOP_, name)))

MODULE = Text::Xslate    PACKAGE = Text::Xslate

PROTOTYPES: DISABLE


BOOT:
{
    HV* const ops = get_hv("Text::Xslate::_ops", GV_ADDMULTI);
    REG_TXOP(noop);
    REG_TXOP(move_sa_to_sb);
    REG_TXOP(literal);
    REG_TXOP(fetch);
    REG_TXOP(fetch_field);
    REG_TXOP(fetch_iter);

    REG_TXOP(print);
    REG_TXOP(print_s);
    REG_TXOP(print_raw);
    REG_TXOP(print_raw_s);

    REG_TXOP(for_start);
    REG_TXOP(for_next);

    REG_TXOP(add);
    REG_TXOP(sub);

    REG_TXOP(cond_expr);
    REG_TXOP(and);
    REG_TXOP(or);
    REG_TXOP(not);
    REG_TXOP(eq);
    REG_TXOP(ne);
    REG_TXOP(lt);
    REG_TXOP(le);
    REG_TXOP(gt);
    REG_TXOP(ge);

    REG_TXOP(pc_inc);
    REG_TXOP(goto);
}

SV*
new(SV* klass, AV* proto)
CODE:
{
    if(SvROK(klass)) {
        croak("Cannot call new as an instance method");
    }

    RETVAL = newRV_noinc((SV*)newHV());
    sv_bless(RETVAL, gv_stashsv(klass, GV_ADD));

    {
        MAGIC* mg;
        HV* const ops = get_hv("Text::Xslate::_ops", GV_ADD);
        I32 const len = av_len(proto) + 1;
        I32 i;
        tx_code_t* code;
        tx_state_t st;

        Zero(&st, 1, tx_state_t);

        st.sa       = &PL_sv_undef;
        st.sb       = &PL_sv_undef;

        st.iter_v   = newAV();
        st.iter_i   = newAV();

        Newxz(code, len, tx_code_t);

        st.code     = code;
        st.code_len = len;
        mg = sv_magicext(SvRV(RETVAL), NULL, PERL_MAGIC_ext, &xslate_vtbl, (char*)&st, sizeof(st));
        mg->mg_private = 1; /* initial hint size */

        for(i = 0; i < len; i++) {
            SV* const pair = *av_fetch(proto, i, TRUE);
            if(SvROK(pair) && SvTYPE(SvRV(pair)) == SVt_PVAV) {
                AV* const av     = (AV*)SvRV(pair);
                SV* const opname = *av_fetch(av, 0, TRUE);
                SV** const arg   =  av_fetch(av, 1, FALSE);
                HE* const he     = hv_fetch_ent(ops, opname, FALSE, 0U);
                SV* opnum;

                if(!he){
                    croak("Unknown opcode '%"SVf"' on [%d]", opname, (int)i);
                }

                opnum             = hv_iterval(ops, he);
                code[i].exec_code = tx_opcode[ SvIV(opnum) ];
                if(arg) {
                    if(SvIV(opnum) == TXOP_fetch) {
                        STRLEN len;
                        const char* const pv = SvPV_const(*arg, len);
                        code[i].arg = newSVpvn_share(pv, len, 0U);
                    }
                    else {
                        code[i].arg = newSVsv(*arg);
                    }
                }
            }
            else {
                croak("Broken code found on [%d]", (int)i);
            }
        }
    }
}
OUTPUT:
    RETVAL

SV*
render(HV* self, HV* hv)
CODE:
{
    MAGIC* const mg      = mgx_find(aTHX_ (SV*)self, &xslate_vtbl);
    tx_state_t* const st = (tx_state_t*)mg->mg_ptr;
    STRLEN hint_size;
    assert(st);

    RETVAL = sv_2mortal(newSV( mg->mg_private << TX_BUFFER_SIZE_C ));
    sv_setpvs(RETVAL, "");

    st->output = RETVAL;
    st->vars   = hv;

    xslate_exec(aTHX_ st);

    /* store a hint size for the next time */
    hint_size = SvCUR(RETVAL) >> TX_BUFFER_SIZE_C;
    if(hint_size > mg->mg_private) {
        mg->mg_private = (U16)(hint_size > U16_MAX ? U16_MAX : hint_size);
    }

    ST(0) = RETVAL;
    XSRETURN(1);
}

