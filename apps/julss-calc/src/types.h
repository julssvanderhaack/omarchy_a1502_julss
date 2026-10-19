// Plain data shared between the CAS thread and the GUI thread.
// Nothing in here touches Giac, so the GUI never needs its headers.
#pragma once
#include <QString>
#include <QStringList>
#include <QPointF>
#include <QVariantMap>
#include <QJsonValue>
#include <complex>
#include <memory>
#include <vector>
#include <cmath>

// ---------------------------------------------------------------- formulas
struct MNode;
using MPtr = std::shared_ptr<const MNode>;

struct MNode {
    enum Kind {
        Row,     // children side by side
        Num,     // upright number
        Var,     // italic identifier
        Op,      // binary operator / relation with spacing
        Text,    // upright text (function names, words)
        Frac,    // c[0] over c[1]
        Pow,     // c[0] raised to c[1]
        Sub,     // c[0] with subscript c[1]
        Sqrt,    // root of c[0], optional index c[1]
        Paren,   // text = "()", "[]", "{}", "||" around c[0]
        Conj,    // overline
        Matrix,  // n columns, children row-major
        BigOp,   // text = "∫" or "∑"; c[0] body, c[1] lower, c[2] upper (may be null)
        Under,   // c[0] with c[1] centred underneath (lim)
        Space    // n = width in 1/18 em
    };
    Kind kind = Row;
    QString text;
    std::vector<MPtr> c;
    int n = 0;
};

namespace M {
MPtr row(std::vector<MPtr> c);
MPtr num(const QString &s);
MPtr var(const QString &s);
MPtr op(const QString &s);
MPtr text(const QString &s);
MPtr frac(MPtr a, MPtr b);
MPtr pow(MPtr a, MPtr b);
MPtr sub(MPtr a, MPtr b);
MPtr sqrt(MPtr a, MPtr idx = nullptr);
MPtr paren(MPtr a, const QString &kind = "()");
MPtr conj(MPtr a);
MPtr matrix(int cols, std::vector<MPtr> cells);
MPtr bigop(const QString &sym, MPtr body, MPtr lo, MPtr hi);
MPtr under(MPtr a, MPtr b);
MPtr space(int eighteenths);
QJsonValue toJson(const MPtr &n);
MPtr fromJson(const QJsonValue &v);
}

// ------------------------------------------------- compiled numeric program
// Stack bytecode evaluated in real or complex arithmetic. Built from a Giac
// expression in the CAS thread, evaluated millions of times by the plotters.
struct Program {
    enum Op : uint8_t {
        Const, Var, Add, Sub, Mul, Div, Neg, Pow, PowInt, RootOdd,
        Sin, Cos, Tan, Asin, Acos, Atan, Sinh, Cosh, Tanh, Asinh, Acosh, Atanh,
        Sec, Csc, Cot, Exp, Ln, Log10, Sqrt, Abs, Sign, Floor, Ceil, Round,
        Re, Im, Arg, Conj, Erf, Gamma, Min, Max, Atan2, Heaviside,
        Lt, Le, Gt, Ge, Eq, Ne, And, Or, Ifte
    };
    struct Ins { Op op; int a = 0; double p = 0, q = 0; };
    std::vector<Ins> code;
    std::vector<std::complex<double>> consts;
    int nvars = 0;
    bool valid = false;

    double eval(const double *v) const;
    std::complex<double> evalc(const std::complex<double> *v) const;
    double eval1(double x) const { return eval(&x); }
    double eval2(double x, double y) const { double v[2] = {x, y}; return eval(v); }
};

// --------------------------------------------------------------- plot spec
struct Series {
    enum Kind {
        Func,      // y = p[0](x)
        Implicit,  // p[0](x,y) = 0
        Region,    // all p[i](x,y) rel[i] 0
        Param2,    // (p[0](t), p[1](t))
        Surface,   // z = p[0](x,y)
        Param3,    // (p[0](t), p[1](t), p[2](t))
        Domain,    // complex p[0](z), domain colouring
        XBand,     // shaded x intervals
        Points,    // marked points
        Fill,      // area under p[0] between a and b
        Implicit3  // p[0](x,y,z) = 0, drawn by marching tetrahedra
    };
    enum Rel { Lt, Le, Gt, Ge, Ne };
    Kind kind = Func;
    std::vector<Program> p;
    std::vector<int> rel;
    std::vector<std::pair<double, double>> intervals;
    std::vector<QPointF> pts;
    double a = 0, b = 0;
    MPtr label;
    int color = -1;        // -1 = next in palette
    bool dashed = false;
    bool complexParts = false; // Func whose values are complex: draw Re and Im
};

struct PlotSpec {
    bool is3D = false;
    std::vector<Series> series;
    QString xname = "x", yname = "y", zname = "z";
    double xmin = -10, xmax = 10;
    double ymin = NAN, ymax = NAN;   // NAN = automatic
    double tmin = -10, tmax = 10;
    bool equalAspect = false;
};
using PlotPtr = std::shared_ptr<const PlotSpec>;

// ------------------------------------------------------- requests/results
struct ResultItem {
    QString caption;   // small grey title ("Forma polar", "Vértices"...)
    MPtr formula;
    QString text;      // copyable plain text (Giac syntax)
    QString latex;
};

struct Request {
    enum Kind { Eval, Preview, Solve, Calc, Plot, Define, Undefine, Reset };
    int id = 0;
    Kind kind = Eval;
    QString text;
    QStringList lines;
    QVariantMap params;
    bool deg = false;
    int digits = 12;
};

struct Response {
    int id = 0;
    Request::Kind kind = Request::Eval;
    bool ok = true;
    QString error;
    std::vector<ResultItem> items;
    PlotPtr plot;
    MPtr preview;
    QString definition;        // giac source to replay on next start
    QString definedName;
    QStringList itemErrors;    // per plotted line (Plot)
    QString summary;           // short plain text (history)
};
