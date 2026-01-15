ENDPOINT_URL="http://localhost:8080"
curl -X POST ${ENDPOINT_URL}/auth/token \
  -H "Content-Type: application/json" \
  -d '{
    "username": "airflow",
    "password": "airflow"
  }'

ENDPOINT_URL="http://localhost:8080"
token="eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIiwianRpIjoiYzU5MzRhZmRjMDlhNDZjYzgzN2Y1MzdhZjEyNGFkMGUiLCJpc3MiOltdLCJhdWQiOiJhcGFjaGUtYWlyZmxvdyIsIm5iZiI6MTc2NzU0NTA1MSwiZXhwIjoxNzY3NjMxNDUxLCJpYXQiOjE3Njc1NDUwNTF9.mGTa32P9xstxHZtVeeBxUqAqkWmsMvhFc92B1hXzRtiSOek5qRM8EwFDBQlPW1qlEsIbA6c-KOF58SqSCdU4Qw"
curl -H "Content-Type: application/json" -H "Authorization: Bearer ${token}" -X GET ${ENDPOINT_URL}/api/v2/users/me
  

token="eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIiwianRpIjoiZGJiMDhmZGEyODAxNGMwYWEyZWIzYzlmN2E1MjVmZmUiLCJpc3MiOltdLCJhdWQiOiJhcGFjaGUtYWlyZmxvdyIsIm5iZiI6MTc2NzU0NTI0OCwiZXhwIjoxNzY3NjMxNjQ4LCJpYXQiOjE3Njc1NDUyNDh9.cf3aUXdhfGi6U8k4MyiqEd-ZT0zHEw6-gzdd2mf8DZmqHw1ocbgc98nlUn6w1J005ItknMU8rfTT412wgTS6yA"
curl -H "Content-Type: application/json" -u "airflow:airflow" -X GET ${ENDPOINT_URL}/auth/fab/v1/users
