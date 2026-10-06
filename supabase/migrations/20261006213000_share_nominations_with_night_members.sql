-- Let authenticated members of a movie night read that night's submitted titles.
drop policy if exists member_nomination_titles_read on public.movie_nominations;
create policy member_nomination_titles_read on public.movie_nominations
  for select to authenticated using(public.is_night_member(night_id));

-- Enable immediate nomination-list refreshes where Supabase Realtime is available.
do $$
begin
  if exists (
    select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime'
  ) and not exists (
    select 1 from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'movie_nominations'
  ) then
    execute 'alter publication supabase_realtime add table public.movie_nominations';
  end if;
end;
$$;
