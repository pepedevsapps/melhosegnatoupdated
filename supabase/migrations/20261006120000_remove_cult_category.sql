-- Remove Cult from future category choices without deleting historical references.
delete from public.film_categories c
where lower(c.name) = 'cult'
  and not exists (
    select 1 from public.night_participants np where np.category_id = c.id
  )
  and not exists (
    select 1 from public.movie_nominations mn where mn.category_id = c.id
  )
  and not exists (
    select 1 from public.drawn_films df where df.category_id = c.id
  );
