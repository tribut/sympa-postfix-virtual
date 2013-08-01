sympa-postfix-virtual
=====================

A drop-in replacement of alias_manager.pl that generates regexp-type virtual aliases for postfix. Using this approach, no suid binary ("aliaswrapper") is needed and messages to nonexisting lists are properly rejected at smtp-time.

For a destailed description please see this [this howto](https://tribut.de/blog/sympa-and-postfix/).
