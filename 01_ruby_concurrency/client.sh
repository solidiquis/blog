for _ in {1..20}; do
  echo "soup" | nc localhost 8080 &
done

for job in `jobs -p`; do
  wait $job
done
