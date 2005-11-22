#ifndef DSDC_MATCH_H
#define DSDC_MATCH_H

/*
 * $Id$
 */


#include "dsdc_prot.h"

#ifndef DSDC_NO_CUPID

void
compute_match(
    matchd_qanswer_rows_t &q1,
    matchd_qanswer_rows_t &q2,
    matchd_frontd_match_datum_t &datum);
#endif /* !DSDC_NO_CUPID */

#endif
