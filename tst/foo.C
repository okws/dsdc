
#include "itree.h"

struct node_t {
    node_t (int i) : k (i) {}
    int k;
    itree_entry<node_t> lnk;
};

int
main (int argc, char *argv[])
{
    itree<int, node_t, &node_t::k, &node_t::lnk> tree;

    for (int i = 0; i < 20; i++)
        tree.insert (New node_t (i));

    tree.deleteall_correct ();

}
