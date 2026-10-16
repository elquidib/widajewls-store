-- Defense in depth: client-side compression is not a server-side upload limit.
-- 3 MiB leaves headroom over the admin's 1–2 MiB optimized image targets.
update storage.buckets
set file_size_limit = 3145728
where id = 'product-images';
