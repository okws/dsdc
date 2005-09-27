/*
 * $Id$
 */

#include <math.h>
#include "dsdc_match.h"

/*
 * XXX: this should be configurable.
 */
static int
getImportance(const matchd_qanswer_row_t &answer)
{
    int result;
    switch (answer.importance) {
        case 1:
            result = 250;
            break;
        case 2:
            result = 50;
            break;
        case 3:
            result = 10;
            break;
        case 4:
            result = 1;
            break;
        case 5:
            result = 0;
            break;
    }
    return result;
}

static int
getMatchAnswer(matchd_qanswer_row_t &answer)
{

    if (answer.answer == 0)
        return (0);
    else
        return (1 << (answer.answer - 1));
}

static int
getMatchWantedMask(matchd_qanswer_row_t &answer)
{

    return answer.match_answer;
}

static double
calcMatchAvg(
    int common,
    int u1possible, int u2possible,
    int u1actual, int u2actual,
    bool lowerconfidence = true)
{
    double result(0.0);
    double u1percent(0.0);
    double u2percent(0.0);

    if (u1possible > 0) {
        u1percent = ((double)u1actual) / u1possible;
    }
    if (u2possible > 0) {
        u2percent = ((double)u2actual) / u2possible;
    }

    result = sqrt(u1percent * u2percent);

    double delta(0.0);
    if (common > 0) {
        delta = 1 / sqrt(common);
    }
    if (lowerconfidence) {
	    result -= delta;
	    if (result < 0.0) {
	        result = 0.0;
	    }
    } else {
	result += delta;
	if (result > 1.0) {
	    result = 1.0;
	}
    }
    return result;
}

void
compute_match(
    matchd_qanswer_rows_t &q1,
    matchd_qanswer_rows_t &q2,
    matchd_frontd_match_datum_t &datum)
{
    unsigned int i, j;

    int common = 0;
    int u1possible = 0;
    int u2possible = 0;
    int friend_u1actual = 0;
    int friend_u2actual = 0;
    int match_u1actual = 0;
    int match_u2actual = 0;

    i = 0;
    j = 0;

    for (i = 0; i < q1.size(); i++) {
        /*
         * both lists should be sorted by question id.
         * So first traverse q2 until we hit a question that matches.
         */
        while (q1[i].questionid > q2[j].questionid && j < q2.size())
            j++;
        /* if we exhausted the list then we're done. */
        if (j == q2.size())
            break;
        /*
         * if we're now greater but not the same question, then loop
         * to advance our cursor into the first list.
         */
        if (q1[i].questionid < q2[j].questionid)
            continue;

        /*
         * ok, we got matching question ids!
         */
        // convenient accessors.
        matchd_qanswer_row_t &q1r = q1[i];
        matchd_qanswer_row_t &q2r = q2[i];

        // both need to answer or we skip it.
        if (getMatchAnswer(q1r) == 0 || getMatchAnswer(q2r) == 0)
            continue;

        int points1 = getImportance(q1r);
        int points2 = getImportance(q2r);

        common++;
        u1possible += points1;
        u2possible += points2;
        /*
         * If they had the same answer, then give them
         * actual friend points.
         */
        if (getMatchAnswer(q1r) == getMatchAnswer(q2r)) {
            friend_u1actual += points1;
            friend_u2actual += points2;
        }

        /*
         * Ok now do actual match points.
         * If they fit each other's expectations, then give
         * each other actual points.
         */
        if ((getMatchAnswer(q1r) & getMatchWantedMask(q2r)) != 0) {
            match_u1actual += points1;
        }
        if ((getMatchAnswer(q2r) & getMatchWantedMask(q1r)) != 0) {
            match_u2actual += points2;
        }
    }

    double match_avg = calcMatchAvg(common,
                                    u1possible, u2possible,
				    match_u1actual, match_u2actual);
    double friend_avg = calcMatchAvg(common,
                                     u1possible, u2possible,
				     friend_u1actual, friend_u2actual);
    double enemy_avg = calcMatchAvg(common,
                                     u1possible, u2possible,
				     friend_u1actual, friend_u2actual, false);

    if (common > 0) {
        /*
	 * This boosts the friend average a little.
         */
        friend_avg += (0.5 - (friend_avg / 2.0));
        /*
         * This is disabled as it's already done inside of calcMatchAvg()
         * but for some reason looks like it's repeated inside
         * matchd_db_t::calcMatchFriend as a bug???
         */
#if 0
        friend_avg -= (1 / sqrt(common));
        if (friend_avg < 0) {
            friend_avg = 0;
        }
#endif
    }

    datum.mpercent = (int)(match_avg * 100.0);
    datum.fpercent = (int)(friend_avg * 100.0);
    datum.epercent = (int)(enemy_avg * 100.0);
}

