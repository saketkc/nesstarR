/*
 * nesstar.c — NESSTAR binary container parser for R.
 *
 * All multi-byte integers in the container are little-endian (both modern
 * HCES 2022-23 and older NSS 64th round files). Variable-directory entry
 * fields are always little-endian regardless of file variant.
 */

#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

/* mode_code values */
#define MODE_STRING  1
#define MODE_NUMERIC 5

/* value_format_code values */
#define FMT_NIBBLE  2
#define FMT_BYTE    3
#define FMT_UINT16  4
#define FMT_UINT24  5
#define FMT_UINT32  6
#define FMT_UINT40  7
#define FMT_FLOAT64 10


static uint8_t  u8(const uint8_t *d, size_t off)  { return d[off]; }
static uint16_t u16le(const uint8_t *d, size_t off) {
    return (uint16_t)(d[off] | ((uint16_t)d[off+1] << 8));
}
static uint32_t u32le(const uint8_t *d, size_t off) {
    return (uint32_t)d[off]        | ((uint32_t)d[off+1] <<  8) |
           ((uint32_t)d[off+2] << 16) | ((uint32_t)d[off+3] << 24);
}
static uint32_t u32be(const uint8_t *d, size_t off) {
    return ((uint32_t)d[off] << 24) | ((uint32_t)d[off+1] << 16) |
           ((uint32_t)d[off+2] <<  8) |  (uint32_t)d[off+3];
}
static int64_t i64le(const uint8_t *d, size_t off) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= ((uint64_t)d[off+i] << (8*i));
    return (int64_t)v;
}
static double f64le(const uint8_t *d, size_t off) {
    double v; memcpy(&v, d+off, 8); return v;
}

static char *utf16le_to_utf8(const uint8_t *src, size_t byte_len) {
    /* Only handle BMP (U+0000..U+FFFF); surrogate pairs become '?'. */
    size_t max_chars = byte_len / 2;
    char *out = (char *)R_alloc(max_chars * 3 + 1, 1);
    size_t w = 0;
    for (size_t i = 0; i < max_chars; i++) {
        uint16_t cp = u16le(src, i * 2);
        if (cp == 0) break;
        if (cp < 0x80) {
            out[w++] = (char)cp;
        } else if (cp < 0x800) {
            out[w++] = (char)(0xC0 | (cp >> 6));
            out[w++] = (char)(0x80 | (cp & 0x3F));
        } else {
            out[w++] = (char)(0xE0 | (cp >> 12));
            out[w++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            out[w++] = (char)(0x80 | (cp & 0x3F));
        }
    }
    out[w] = '\0';
    return out;
}

/* Returns 1 for little-endian, 0 for big-endian. */
static int detect_byte_order(const uint8_t *data, size_t len) {
    if (len < 0x29) return 1;
    uint32_t le = u32le(data, 0x25);
    if (le + 4 <= (uint32_t)len) return 1;
    uint32_t be = u32be(data, 0x25);
    if (be + 4 <= (uint32_t)len) return 0;
    return 1;
}

static uint32_t read_u32(const uint8_t *d, size_t off, int little_endian) {
    return little_endian ? u32le(d, off) : u32be(d, off);
}
static uint16_t read_u16(const uint8_t *d, size_t off, int little_endian) {
    if (little_endian) return u16le(d, off);
    return (uint16_t)(((uint16_t)d[off] << 8) | d[off+1]);
}


#define MAX_RESOURCES 200000

typedef struct {
    uint32_t record_id;
    uint32_t target_offset;
    uint32_t length;
} ResRecord;

typedef struct {
    ResRecord *records;
    uint32_t   count;
} ResIndex;

static ResIndex parse_resource_index(const uint8_t *data, size_t len, int le) {
    ResIndex idx = {NULL, 0};
    if (len < 0x29) return idx;
    uint32_t off = read_u32(data, 0x25, le);
    if ((size_t)off + 4 > len) return idx;
    uint32_t count = read_u32(data, off, le);
    if (count == 0 || count > MAX_RESOURCES) return idx;
    size_t end = (size_t)off + 4 + (size_t)count * 15;
    if (end > len) return idx;
    ResRecord *recs = (ResRecord *)R_alloc(count, sizeof(ResRecord));
    size_t cur = off + 4;
    for (uint32_t i = 0; i < count; i++) {
        recs[i].record_id     = read_u32(data, cur,    le);
        recs[i].target_offset = read_u32(data, cur+4,  le);
        recs[i].length        = read_u32(data, cur+10, le);
        cur += 15;
    }
    idx.records = recs;
    idx.count   = count;
    return idx;
}

static ResRecord *find_record(const ResIndex *idx, uint32_t id) {
    for (uint32_t i = 0; i < idx->count; i++)
        if (idx->records[i].record_id == id) return &idx->records[i];
    return NULL;
}

static int is_plausible_name(const char *s) {
    if (!s || !s[0]) return 0;
    if (!((s[0] >= 'A' && s[0] <= 'Z') || (s[0] >= 'a' && s[0] <= 'z') || s[0] == '_'))
        return 0;
    for (int i = 1; s[i]; i++) {
        char c = s[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '_')) return 0;
        if (i > 40) return 0;
    }
    return 1;
}

/*
 * nesstar_parse_binary(raw_bytes)
 * raw_bytes: raw vector (the full file contents)
 *
 * Returns a named list:
 *   $byte_order     : character "little" or "big"
 *   $dataset_count  : integer
 *   $datasets       : list of per-dataset lists:
 *     $dataset_number, $variable_count, $row_count
 *     $variables: list of per-variable lists:
 *       $name, $variable_id, $mode_code, $value_format_code,
 *       $value_offset_i64, $width_value, $data_offset, $data_length
 */
SEXP nesstar_parse_binary(SEXP raw_bytes) {
    if (TYPEOF(raw_bytes) != RAWSXP)
        error("nesstar_parse_binary: expected a raw vector");

    const uint8_t *data = RAW(raw_bytes);
    size_t len = (size_t)XLENGTH(raw_bytes);

    if (len < 8 || memcmp(data, "NESSTART", 8) != 0)
        error("Not a NESSTAR file: missing NESSTART magic");

    int le = detect_byte_order(data, len);

    ResIndex idx = parse_resource_index(data, len, le);
    if (!idx.records)
        error("Could not parse trailing resource index");

    uint32_t base_id = read_u32(data, 0x2F, le);
    ResRecord *base_rec = find_record(&idx, base_id);
    if (!base_rec)
        error("Resource index has no record for base_record_id %u", base_id);

    int ds_count     = (int)u8(data, 0x2B);
    uint16_t rec_sz  = read_u16(data, 0x2D, le);
    if (rec_sz < 26)
        error("Descriptor record size %u too small", rec_sz);

    uint32_t desc_off = base_rec->target_offset;
    if ((size_t)desc_off + (size_t)ds_count * rec_sz > len)
        error("Descriptor table extends beyond end of file");

    SEXP datasets = PROTECT(allocVector(VECSXP, ds_count));

    for (int d = 0; d < ds_count; d++) {
        size_t doff = (size_t)desc_off + (size_t)d * rec_sz;
        uint32_t ds_num    = read_u32(data, doff,    le);
        uint32_t var_count = read_u32(data, doff+4,  le);
        uint32_t row_count = read_u32(data, doff+8,  le);
        uint32_t row_copy  = read_u32(data, doff+12, le);
        uint32_t fd_rec_id = read_u32(data, doff+16, le);
        uint16_t entry_sz  = read_u16(data, doff+20, le);
        uint32_t dir_rec_id= read_u32(data, doff+22, le);

        if (row_copy != row_count)
            error("Dataset %u: row_count mismatch (%u vs %u)", ds_num, row_count, row_copy);

        /* Directory location */
        ResRecord *dir_rec = find_record(&idx, dir_rec_id);
        if (!dir_rec)
            error("Dataset %u: no resource record for dir_record_id %u", ds_num, dir_rec_id);
        if (entry_sz < 160)
            error("Dataset %u: variable_directory_entry_size %u too small", ds_num, entry_sz);

        uint32_t dir_off = dir_rec->target_offset;
        if ((size_t)dir_off + (size_t)var_count * entry_sz > len)
            error("Dataset %u: variable directory extends beyond file", ds_num);

        SEXP variables = PROTECT(allocVector(VECSXP, (int)var_count));
        static const char *var_names[] = {
            "name","variable_id","mode_code","value_format_code",
            "value_offset_i64","width_value","data_offset","data_length",
            "label_resource_id","category_resource_id","object_id",""
        };

        for (uint32_t v = 0; v < var_count; v++) {
            size_t voff = (size_t)dir_off + (size_t)v * entry_sz;
            /* Name: bytes 63..126 = 64 bytes UTF-16LE */
            char *name = utf16le_to_utf8(data + voff + 63, 64);
            if (!is_plausible_name(name))
                error("Dataset %u variable %u: implausible name '%s'", ds_num, v, name);

            uint32_t var_id     = u32le(data, voff + 15);
            uint8_t  mode       = u8(data,    voff + 159);
            uint8_t  fmt        = u8(data,    voff + 5);
            int64_t  offset_i64 = i64le(data, voff + 6);
            uint8_t  width      = u8(data,    voff + 149);
            uint32_t lbl_rec_id = u32le(data, voff + 127);
            uint16_t cat_rec_id = u16le(data, voff + 131);
            uint32_t obj_id     = u32le(data, voff + 155);

            /* Look up data offset/length in resource index */
            ResRecord *var_rec = find_record(&idx, var_id);
            uint32_t data_offset = var_rec ? var_rec->target_offset : 0;
            uint32_t data_length = var_rec ? var_rec->length        : 0;

            SEXP var_list = PROTECT(mkNamed(VECSXP, var_names));
            SET_VECTOR_ELT(var_list, 0,  mkString(name));
            SET_VECTOR_ELT(var_list, 1,  ScalarInteger((int)var_id));
            SET_VECTOR_ELT(var_list, 2,  ScalarInteger((int)mode));
            SET_VECTOR_ELT(var_list, 3,  ScalarInteger((int)fmt));
            SET_VECTOR_ELT(var_list, 4,  ScalarReal((double)offset_i64));
            SET_VECTOR_ELT(var_list, 5,  ScalarInteger((int)width));
            SET_VECTOR_ELT(var_list, 6,  ScalarReal((double)data_offset));
            SET_VECTOR_ELT(var_list, 7,  ScalarReal((double)data_length));
            SET_VECTOR_ELT(var_list, 8,  ScalarInteger((int)lbl_rec_id));
            SET_VECTOR_ELT(var_list, 9,  ScalarInteger((int)cat_rec_id));
            SET_VECTOR_ELT(var_list, 10, ScalarInteger((int)obj_id));
            SET_VECTOR_ELT(variables, (int)v, var_list);
            UNPROTECT(1);
        }

        static const char *ds_names[] = {
            "dataset_number","variable_count","row_count",
            "file_description_record_id","variables",""
        };
        SEXP ds_list = PROTECT(mkNamed(VECSXP, ds_names));
        SET_VECTOR_ELT(ds_list, 0, ScalarInteger((int)ds_num));
        SET_VECTOR_ELT(ds_list, 1, ScalarInteger((int)var_count));
        SET_VECTOR_ELT(ds_list, 2, ScalarInteger((int)row_count));
        SET_VECTOR_ELT(ds_list, 3, ScalarInteger((int)fd_rec_id));
        SET_VECTOR_ELT(ds_list, 4, variables);
        SET_VECTOR_ELT(datasets, d, ds_list);
        UNPROTECT(2); /* variables, ds_list */
    }

    static const char *top_names[] = {"byte_order","datasets",""};
    SEXP result = PROTECT(mkNamed(VECSXP, top_names));
    SET_VECTOR_ELT(result, 0, mkString(le ? "little" : "big"));
    SET_VECTOR_ELT(result, 1, datasets);

    UNPROTECT(2); /* datasets, result */
    return result;
}

/* Huffman XML block decoder */

#define MAX_SYMBOLS 256
#define MAX_CODE_LEN 32

typedef struct HNode {
    int symbol;   /* -1 for internal node */
    int left, right; /* child indices, -1 for leaves */
} HNode;

static int hnode_pool_n;
static HNode hnode_pool[MAX_SYMBOLS * 2 + 4];

static int new_node(int sym, int l, int r) {
    int idx = hnode_pool_n++;
    hnode_pool[idx].symbol = sym;
    hnode_pool[idx].left   = l;
    hnode_pool[idx].right  = r;
    return idx;
}

/* Min-heap over (freq, counter, node_index) */
typedef struct { uint64_t freq; int counter; int node; } HeapItem;
static HeapItem heap[MAX_SYMBOLS * 2 + 4];
static int heap_n;

static void heap_push(HeapItem item) {
    int i = heap_n++;
    heap[i] = item;
    while (i > 0) {
        int p = (i - 1) / 2;
        if (heap[p].freq < heap[i].freq ||
            (heap[p].freq == heap[i].freq && heap[p].counter < heap[i].counter))
            break;
        HeapItem tmp = heap[p]; heap[p] = heap[i]; heap[i] = tmp;
        i = p;
    }
}

static HeapItem heap_pop(void) {
    HeapItem top = heap[0];
    heap[0] = heap[--heap_n];
    int i = 0;
    for (;;) {
        int l = 2*i+1, r = 2*i+2, s = i;
        if (l < heap_n && (heap[l].freq < heap[s].freq ||
            (heap[l].freq == heap[s].freq && heap[l].counter < heap[s].counter))) s = l;
        if (r < heap_n && (heap[r].freq < heap[s].freq ||
            (heap[r].freq == heap[s].freq && heap[r].counter < heap[s].counter))) s = r;
        if (s == i) break;
        HeapItem tmp = heap[s]; heap[s] = heap[i]; heap[i] = tmp;
        i = s;
    }
    return top;
}

/*
 * nesstar_decode_huffman(raw_bytes, offset, has_dataset_index)
 * Decodes one Huffman-compressed XML block.
 * Returns a character scalar (the decoded XML string).
 */
SEXP nesstar_decode_huffman(SEXP raw_bytes, SEXP r_offset, SEXP r_has_ds_idx) {
    if (TYPEOF(raw_bytes) != RAWSXP) error("expected raw vector");
    const uint8_t *data = RAW(raw_bytes);
    size_t len  = (size_t)XLENGTH(raw_bytes);
    size_t base = (size_t)asInteger(r_offset);
    int has_ds  = asLogical(r_has_ds_idx);

    if (base >= len) error("offset %zu beyond file length %zu", base, len);

    size_t pos = base;
    if (has_ds) {
        if (pos >= len) error("truncated: no dataset-index byte");
        pos++; /* skip dataset-index byte (not used in output) */
    }

    if (pos >= len) error("truncated: no symbol_count");
    int sym_count = (int)data[pos++];
    if (sym_count < 1 || sym_count > MAX_SYMBOLS)
        error("invalid symbol_count %d at offset %zu", sym_count, pos-1);

    pos++; /* reserved byte */
    pos++; /* second reserved byte */

    if (pos + (size_t)sym_count * 5 > len)
        error("symbol table truncated");

    uint8_t  syms[MAX_SYMBOLS];
    uint32_t freqs[MAX_SYMBOLS];
    uint64_t total_freq = 0;
    for (int i = 0; i < sym_count; i++) {
        syms[i]  = data[pos];
        freqs[i] = u32le(data, pos+1);
        if (freqs[i] == 0) error("symbol %d has zero frequency", i);
        total_freq += freqs[i];
        pos += 5;
    }

    if (pos + 4 > len) error("truncated: no output_length");
    uint32_t output_len = u32le(data, pos);
    pos += 4;

    if ((uint64_t)output_len != total_freq)
        error("output_length %u != sum of frequencies %llu",
              output_len, (unsigned long long)total_freq);

    hnode_pool_n = 0;
    heap_n       = 0;
    int counter  = 0;

    for (int i = 0; i < sym_count; i++) {
        int n = new_node((int)syms[i], -1, -1);
        HeapItem item = {freqs[i], counter++, n};
        heap_push(item);
    }

    int root = 0;
    while (heap_n > 1) {
        HeapItem a = heap_pop();
        HeapItem b = heap_pop();
        int n = new_node(-1, a.node, b.node);
        HeapItem item = {a.freq + b.freq, counter++, n};
        heap_push(item);
    }
    root = heap[0].node;

    if (output_len > 10 * 1024 * 1024)
        error("output_length %u implausibly large", output_len);
    char *out = (char *)R_alloc(output_len + 1, 1);
    uint32_t out_pos = 0;
    size_t   bit_pos = 0; /* bit index into data[pos..] */

    if (sym_count == 1) {
        /* One-symbol code: all bits are 0 → always go left */
        for (uint32_t i = 0; i < output_len; i++)
            out[i] = (char)syms[0];
    } else {
        while (out_pos < output_len) {
            int node = root;
            while (hnode_pool[node].symbol == -1) {
                size_t byte_idx = pos + bit_pos / 8;
                if (byte_idx >= len) error("Huffman payload truncated");
                int bit = (data[byte_idx] >> (bit_pos % 8)) & 1;
                bit_pos++;
                node = bit ? hnode_pool[node].right : hnode_pool[node].left;
                if (node == -1) error("Huffman tree walk out of bounds");
            }
            out[out_pos++] = (char)hnode_pool[node].symbol;
        }
    }
    out[output_len] = '\0';
    return mkString(out);
}

/* ---------------------------------- decode one dataset column to R vector */

/* Shared inner decoder: col points to the start of the column payload,
 * row_start is the first row index to emit, n_rows is the count to emit. */
static SEXP decode_column_impl(const uint8_t *col, int mode, int fmt,
                                double off_i64, int width,
                                int row_start, int n_rows) {
    if (mode == MODE_STRING) {
        if (width <= 0) error("mode 1 variable has width_value <= 0");
        SEXP out = PROTECT(allocVector(STRSXP, n_rows));
        for (int k = 0; k < n_rows; k++) {
            int i = row_start + k;
            const uint8_t *slot = col + (size_t)i * width;
            int slen = 0;
            while (slen < width && slot[slen] != 0) slen++;
            SET_STRING_ELT(out, k, mkCharLen((const char *)slot, slen));
        }
        UNPROTECT(1);
        return out;
    }

    if (mode != MODE_NUMERIC) error("unsupported mode_code %d", mode);

    SEXP out = PROTECT(allocVector(REALSXP, n_rows));
    double *d = REAL(out);

    uint64_t missing_raw = 0;
    int has_missing = 1;
    switch (fmt) {
        case FMT_NIBBLE:  missing_raw = 0x0F;             break;
        case FMT_BYTE:    missing_raw = 0xFF;             break;
        case FMT_UINT16:  missing_raw = 0xFFFF;           break;
        case FMT_UINT24:  missing_raw = 0xFFFFFF;         break;
        case FMT_UINT32:  missing_raw = 0xFFFFFFFF;       break;
        case FMT_UINT40:  missing_raw = 0xFFFFFFFFFFULL;  break;
        case FMT_FLOAT64: has_missing = 0;                break;
        default: error("unsupported value_format_code %d", fmt);
    }

    /* float64 missing: DBL_MAX bytes (0x7fefffffffffffff) */
    double f64_missing = 0.0;
    if (fmt == FMT_FLOAT64) {
        static const uint8_t f64_miss_bytes[8] =
            {0xff,0xff,0xff,0xff,0xff,0xff,0xef,0x7f};
        memcpy(&f64_missing, f64_miss_bytes, 8);
    }

    for (int k = 0; k < n_rows; k++) {
        int i = row_start + k;
        uint64_t raw = 0;
        double val;
        switch (fmt) {
            case FMT_NIBBLE: {
                uint8_t byte = col[i / 2];
                raw = (i % 2 == 0) ? (byte >> 4) & 0x0F : byte & 0x0F;
                val = (double)raw;
                break;
            }
            case FMT_BYTE:
                raw = col[i];
                val = (double)raw;
                break;
            case FMT_UINT16:
                raw = (uint64_t)col[i*2] | ((uint64_t)col[i*2+1] << 8);
                val = (double)raw;
                break;
            case FMT_UINT24:
                raw = (uint64_t)col[i*3]       |
                      ((uint64_t)col[i*3+1] <<  8) |
                      ((uint64_t)col[i*3+2] << 16);
                val = (double)raw;
                break;
            case FMT_UINT32:
                raw = u32le(col, (size_t)i * 4);
                val = (double)raw;
                break;
            case FMT_UINT40:
                raw = (uint64_t)col[i*5]       |
                      ((uint64_t)col[i*5+1] <<  8) |
                      ((uint64_t)col[i*5+2] << 16) |
                      ((uint64_t)col[i*5+3] << 24) |
                      ((uint64_t)col[i*5+4] << 32);
                val = (double)raw;
                break;
            case FMT_FLOAT64:
                val = f64le(col, (size_t)i * 8);
                if (val == f64_missing) { d[k] = NA_REAL; continue; }
                d[k] = val;
                continue;
            default:
                d[k] = NA_REAL;
                continue;
        }
        d[k] = (has_missing && raw == missing_raw) ? NA_REAL : val + off_i64;
    }

    UNPROTECT(1);
    return out;
}

SEXP nesstar_decode_column(SEXP raw_bytes, SEXP r_data_offset, SEXP r_data_len,
                           SEXP r_mode, SEXP r_fmt, SEXP r_offset_i64,
                           SEXP r_width, SEXP r_row_count) {
    const uint8_t *data = RAW(raw_bytes);
    size_t file_len = (size_t)XLENGTH(raw_bytes);
    size_t col_off  = (size_t)asReal(r_data_offset);
    size_t col_len  = (size_t)asReal(r_data_len);
    if (col_off + col_len > file_len)
        error("column data region [%zu, %zu) exceeds file length %zu",
              col_off, col_off + col_len, file_len);
    return decode_column_impl(data + col_off,
                              asInteger(r_mode), asInteger(r_fmt),
                              asReal(r_offset_i64), asInteger(r_width),
                              0, asInteger(r_row_count));
}

SEXP nesstar_decode_column_range(SEXP raw_bytes, SEXP r_data_offset, SEXP r_data_len,
                                 SEXP r_mode, SEXP r_fmt, SEXP r_offset_i64,
                                 SEXP r_width, SEXP r_row_start, SEXP r_n_rows) {
    const uint8_t *data = RAW(raw_bytes);
    size_t file_len = (size_t)XLENGTH(raw_bytes);
    size_t col_off  = (size_t)asReal(r_data_offset);
    size_t col_len  = (size_t)asReal(r_data_len);
    if (col_off + col_len > file_len)
        error("column data region [%zu, %zu) exceeds file length %zu",
              col_off, col_off + col_len, file_len);
    return decode_column_impl(data + col_off,
                              asInteger(r_mode), asInteger(r_fmt),
                              asReal(r_offset_i64), asInteger(r_width),
                              asInteger(r_row_start), asInteger(r_n_rows));
}

/* R registration table */

static const R_CallMethodDef CallEntries[] = {
    {"nesstar_parse_binary",       (DL_FUNC)&nesstar_parse_binary,       1},
    {"nesstar_decode_huffman",     (DL_FUNC)&nesstar_decode_huffman,     3},
    {"nesstar_decode_column",      (DL_FUNC)&nesstar_decode_column,      8},
    {"nesstar_decode_column_range",(DL_FUNC)&nesstar_decode_column_range,9},
    {NULL, NULL, 0}
};

void R_init_nesstarR(DllInfo *dll) {
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
}
