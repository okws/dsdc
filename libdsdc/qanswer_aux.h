#ifndef QANSWER_AUX_H
#define QANSWER_AUX_H
/*
 * Copyright 2005 Okcupid.
 *
 * Author: Alfred Perlstein
 *
 * $Id$
 *
 * Functions for accessing matchd_qanswer_row_t packed fields.
 */

#define QA_ANSWER_MASK		0x03
#define QA_ANSWER_SHIFT		0
#define QA_ANSWER_BITS		2

#define QA_MATCHANSWER_MASK	0x0f
#define QA_MATCHANSWER_SHIFT	(QA_ANSWER_SHIFT + QA_ANSWER_BITS)
#define QA_MATCHANSWER_BITS	4

#define QA_IMPORTANCE_MASK	0x07
#define QA_IMPORTANCE_SHIFT	(QA_MATCHANSWER_SHIFT + QA_MATCHANSWER_BITS)
#define QA_IMPORTANCE_BITS	3

static inline void
qa_init(struct matchd_qanswer_row_t &row)
{
	row.questionid = 0;
	row.data = 0;
}

static inline void
qa_questionid_set(struct matchd_qanswer_row_t &row, int id)
{

	row.questionid = id;
}

static inline int
qa_questionid_get(const struct matchd_qanswer_row_t &row)
{

	return (row.questionid);
}

static inline void
qa_answer_set(struct matchd_qanswer_row_t &row, int ans)
{

	row.data |= (((ans - 1) & QA_ANSWER_MASK) << QA_ANSWER_SHIFT);
}

static inline int
qa_answer_get(const struct matchd_qanswer_row_t &row)
{

	return (((row.data >> QA_ANSWER_SHIFT) & QA_ANSWER_MASK) + 1);
}

static inline void
qa_matchanswer_set(struct matchd_qanswer_row_t &row, int matchans)
{

	// match answers in the database are shifted one bit too far left.
	row.data |= (((matchans >> 1) & QA_MATCHANSWER_MASK) << QA_MATCHANSWER_SHIFT);
}

static inline int
qa_matchanswer_get(const struct matchd_qanswer_row_t &row)
{

	// match answers in the database are shifted one bit too far left.
	return (((row.data >> QA_MATCHANSWER_SHIFT) & QA_MATCHANSWER_MASK) << 1);
}

static inline void
qa_importance_set(struct matchd_qanswer_row_t &row, int importance)
{

	row.data |= ((importance & QA_IMPORTANCE_MASK) << QA_IMPORTANCE_SHIFT);
}

static inline int
qa_importance_get(const struct matchd_qanswer_row_t &row)
{

	return ((row.data >> QA_IMPORTANCE_SHIFT) & QA_IMPORTANCE_MASK);
}

#endif /* !QANSWER_AUX_H */
