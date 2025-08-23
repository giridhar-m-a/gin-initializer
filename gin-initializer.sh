#!/bin/bash

# Prompt for project details
read -p "Enter project name: " PROJECT_NAME
read -p "Enter Go package name (e.g., github.com/user/project): " PACKAGE_NAME

# Create project directory
mkdir -p $PROJECT_NAME
cd $PROJECT_NAME || exit

echo "Initializing Go Gin project: $PROJECT_NAME ($PACKAGE_NAME)"

# Initialize Go module
go mod init $PACKAGE_NAME

# Install dependencies
go get github.com/gin-gonic/gin
go install github.com/kyleconroy/sqlc/cmd/sqlc@latest
go install github.com/golang-migrate/migrate/v4/cmd/migrate@latest
go install github.com/swaggo/swag/cmd/swag@latest
go get github.com/swaggo/gin-swagger
go get github.com/swaggo/files
go get github.com/swaggo/swag@latest



# Create directories
mkdir -p cmd/server \
         internal/{api/handler,domain,repositories,services,db/{migrations,queries,sqlc}} \
         configs

#####################################
# .env.example
#####################################
cat <<EOL > .env.example
# App Config
APP_PORT=8080

# Database Config
DB_USER=user
DB_PASSWORD=password
DB_NAME=db_name
DB_HOST=db
DB_PORT=1234
DB_SSLMODE=disable
EOL

cp .env.example .env

#####################################
# .dockerignore
#####################################
cat <<EOL > .dockerignore
# Binaries
tmp
*.out
*.exe
*.log

# Dependencies
vendor

# Git
.git
.gitignore

# Docker
Dockerfile*
docker-compose*

# Go build
bin
dist

#env
.env
.env.*.local
.env.*
EOL

#####################################
# Dockerfile.dev
#####################################
cat <<'EOL' > Dockerfile.dev
FROM golang:1.24-alpine

WORKDIR /app

# Install build dependencies (git, bash, make)
RUN apk add --no-cache git bash make

# Install Air (for live reload)
RUN go install github.com/air-verse/air@latest&& \
    go install github.com/swaggo/swag/cmd/swag@latest
ENV PATH=$PATH:/go/bin

# Copy dependency files
COPY go.mod go.sum ./ 
RUN go mod download
RUN go mod tidy

# Copy the rest of the project
COPY . .

RUN swag init -g cmd/server/main.go -o docs/ --parseDependency --parseInternal

# Default command: run with Air
CMD ["air", "-c", ".air.toml"]
EOL

#####################################
# docker-compose.yml (dev)
#####################################
cat <<EOL > docker-compose.yml
services:

  db:
    image: postgres:15
    container_name: ${PROJECT_NAME}_db
    restart: always
    env_file:
      - .env
    environment:
      POSTGRES_USER: \${DB_USER}
      POSTGRES_PASSWORD: \${DB_PASSWORD}
      POSTGRES_DB: \${DB_NAME}
    ports:
      - "\${DB_PORT}:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:7
    container_name: ${PROJECT_NAME}_redis
    restart: always
    ports:
      - "6379:6379"

  app:
    build:
      context: .
      dockerfile: Dockerfile.dev
    container_name: ${PROJECT_NAME}_app
    command: air -c .air.toml
    working_dir: /app
    environment:
      - AIR_WATCHER_FORCE_POLLING=true
    env_file:
      - .env
    volumes:
      - .:/app:delegated
      - air_tmp:/app/tmp
    ports:
      - \${APP_PORT}:\${APP_PORT}
    depends_on:
      - db
      - redis

volumes:
  postgres_data:
  air_tmp:
EOL

#####################################
# .air.toml
#####################################
cat <<'EOL' > .air.toml
root = "."
tmp_dir = "tmp"

[build]
  cmd = "go build -buildvcs=false -o ./tmp/main ./cmd/server"
  bin = "tmp/main"
  full_bin = "tmp/main"
  include_ext = ["go", "tpl", "tmpl", "html"]
  exclude_dir = ["assets", "vendor", "internal/db/sqlc"]

[watch]
  dirs = ["."]

[log]
  time = true
EOL

#####################################
# Makefile
#####################################
cat <<'EOL' > Makefile
include .env

export $(shell sed 's/=.*//' .env)

DB_URL=postgresql://$(DB_USER):$(DB_PASSWORD)@localhost:$(DB_PORT)/$(DB_NAME)?sslmode=$(DB_SSLMODE)

dev:
	docker-compose up --build -d

exec:
	docker-compose exec app sh

logs-app:
	docker-compose logs -f app

logs-db:
	docker-compose logs -f db

down:
	docker-compose down

migrate-new:
	migrate create -ext sql -dir internal/db/migrations -seq $(name)

migrate-up:
	migrate -path internal/db/migrations -database "$(DB_URL)" -verbose up

migrate-down:
	migrate -path internal/db/migrations -database "$(DB_URL)" -verbose down
  
sqlc:
	sqlc generate

print-db-url:
	@echo $(DB_URL)

format:
	go fmt ./...

# Swagger documentation
.PHONY: swagger
swagger:
	swag init -g cmd/server/main.go -o docs/ --parseDependency --parseInternal

.PHONY: swagger-serve
swagger-serve: swagger
	@echo "Swagger UI available at: http://localhost:8080/swagger/index.html"
	go run cmd/server/main.go

.PHONY: swagger-clean
swagger-clean:
	rm -rf docs/

EOL

#####################################
# sqlc.yaml
#####################################
cat <<'EOL' > sqlc.yaml
version: "2"
sql:
  - schema: "internal/db/migrations"
    queries: "internal/db/queries"
    engine: "postgresql"
    gen:
      go:
        package: "sqlc"
        out: "internal/db/sqlc"
EOL

#####################################
# .gitignore
#####################################
cat <<'EOL' > .gitignore
# Binaries
tmp/
bin/
dist/

# Logs
*.log

# Dependencies
vendor/

# Environment
.env
.env.*.local
.env.*

# IDE
.vscode/
.idea/
EOL

#####################################
# cmd/server/main.go
#####################################
cat <<EOL > cmd/server/main.go
package main

import (
	"log"
	"os"
	// "fmt"

	"github.com/gin-gonic/gin"
	"$PACKAGE_NAME/internal/api"

	_ "$PACKAGE_NAME/docs" // docs generated by swag
	swaggerFiles "github.com/swaggo/files"
	ginSwagger "github.com/swaggo/gin-swagger"
)

// @title My API
// @version 1.0
// @description This is a sample Gin API
// @host localhost:8080
// @BasePath /api/v1
func main() {
	port := os.Getenv("APP_PORT")
	r := gin.Default()

	// Swagger endpoint
	r.GET("/api/docs", func(c *gin.Context) {
		c.Redirect(301, "/api/docs/index.html")
	})
	r.GET("/api/docs/*any", ginSwagger.WrapHandler(swaggerFiles.Handler))

	// Register API routes
	api.RegisterRoutes(r)

	if port == "" {
		port = "8080"
	}

	log.Printf("Starting server on port %s...", port)
	if err := r.Run(":" + port); err != nil {
		log.Fatalf("Failed to run server: %v", err)
	}
}

EOL

#####################################
# internal/api/route.go
#####################################
cat <<EOL > internal/api/route.go
package api

import (
	"github.com/gin-gonic/gin"
	"$PACKAGE_NAME/internal/api/handler"
)

func RegisterRoutes(r *gin.Engine) {
	api := r.Group("/api/v1")
	handler.RegisterHealth(api)
}
EOL

#####################################
# internal/api/handler/health.go
#####################################
cat <<EOL > internal/api/handler/health.go
package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

// HealthCheck godoc
// @Summary Check API health
// @Description Returns OK if the API is running
// @Tags health
// @Produce json
// @Success 200 {object} map[string]string
// @Router /health [get]
func RegisterHealth(rg *gin.RouterGroup) {
	rg.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{
			"status": "ok",
		})
	})
}

EOL

#####################################
# Initialize git with main branch
#####################################
git init
git branch -M main
git add .
git commit -m "Initial commit - Go Gin project Initialized"
swag init -g cmd/server/main.go -o docs/ --parseDependency --parseInternal
go mod tidy

echo "✅ Project $PROJECT_NAME initialized successfully on branch 'main'!"
echo "-----------------     Next steps:     -----------------"
echo "cd ./${PROJECT_NAME}"
echo "1. Configure your .env file"
echo "2. Run 'make dev' to start the development server"
echo "3. Run 'make test' to execute tests"
