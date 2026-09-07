FROM node:22-alpine AS client
WORKDIR /source/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run build

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source
COPY backend/src/Pryvance.Web/Pryvance.Web.csproj backend/src/Pryvance.Web/
RUN dotnet restore backend/src/Pryvance.Web/Pryvance.Web.csproj
COPY backend/src/Pryvance.Web/ backend/src/Pryvance.Web/
COPY --from=client /source/backend/src/Pryvance.Web/wwwroot \
    backend/src/Pryvance.Web/wwwroot
RUN dotnet publish backend/src/Pryvance.Web/Pryvance.Web.csproj \
    --no-restore --configuration Release --output /app \
    /p:BuildClient=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
RUN apt-get update \
    && apt-get install --yes --no-install-recommends libgssapi-krb5-2 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app ./
USER $APP_UID
ENTRYPOINT ["dotnet", "Pryvance.Web.dll"]
