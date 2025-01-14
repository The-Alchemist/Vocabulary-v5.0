DO $_$
DECLARE
z text;
BEGIN
  z:=$FUNCTIONBODY$
    CREATE OR REPLACE FUNCTION vocabulary_download.run_wget (iPath text, iFilename text, iDownloadLink text, iDeleteAll int default 1, iParams text default '-1')
    RETURNS void AS
    $BODY$#!/bin/bash
    #set permissions=775 by default
    umask 002 && \
    mkdir -p "$1" && \
    cd "$1" && \
    if [[ "$4" = "1" ]] ; then rm -rf *; fi && \
    mkdir -p "work" && \
    if [[ "$5" = "-1" ]] ; then wget --quiet -O "work/$2" "$3"; else code='wget --quiet -O '"work/$2"' '"$5"' '"$3" && eval "$code"; fi
    $BODY$
    LANGUAGE 'plsh'
    SECURITY DEFINER;
  $FUNCTIONBODY$;
  --convert CRLF to LF for bash
  EXECUTE REPLACE(z,E'\r','');
  REVOKE EXECUTE ON FUNCTION vocabulary_download.run_wget FROM PUBLIC, role_read_only;
END $_$;